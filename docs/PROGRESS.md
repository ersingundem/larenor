# Larenor — güncel ilerleme ve iş kuyruğu

**Son durum: 3 Ekim 2026 — tek çalışma dalı `codex/project-completion-100`. Geliştirme ve odaklı doğrulaması tamamlanan 58 seçili özellik / toplam 69 iş CI bekliyor. F60/F62 yeniden çalışılıyor ve yalnız FINAL.FUNCTION aktif. Kanıtla kabul edilen 35/127 iş (%27,6) ve 3/63 seçili özellik (%4,8) değişmedi.** [Güncel kuyruk](EXECUTION_QUEUE.md).

## Güncel durum ayrımı

| Durum | İşler | Kalan kapı |
| --- | --- | --- |
| **CI bekliyor** | **58 seçili özellik / toplam 69 iş; F21/F24/F25/F26/F27 dahil** | Son birleşik dal HEAD’inin geniş Server/Android/Security CI kabulü |
| **CI bekliyor** | **F18** | F27 ortak DB hold/admission ve durable/in-flight drain tamamlandı: root9 odaklı test. NUT listener publication yarışı da kapandı: root28 geçti/1 mevcut Linux-only skip, Ruff ve bağımsız inceleme temiz. Son birleşik CI ve fiziksel UPS kabulü açık. [Güç sırası](testing/f18-f27-offline-power-hold-2026-10-01.md), [socket kanıtı](testing/f18-notify-socket-publication-2026-10-01.md) |
| **Yeniden çalışılıyor** | **F60** | Normal Başlat ve Game spinner sahipliği düzeltmeleri yerel kapıları geçti; [exact-a8 strict 36835162847](https://github.com/ersingundem/larenor/actions/runs/36835162847) original 1/1/0/0 firstStreamOutput ile başarısız. Lease gameVisible, timeout/unknown_effect; frame/PCM/input/iki yaşam/kapanış ve kesin alt neden açık. [Doğrulanmış sonuç](testing/f60-a8-stream-failure-2026-10-01.md) |
| **Yeniden çalışılıyor** | **F62** | Keyboard/Türkçe layout/Unicode, pencere lease ve fit/fill/native geometry dilimleri yerel kapıları geçti. [Exact-42be strict 36836063548](https://github.com/ersingundem/larenor/actions/runs/36836063548) original 1/1/0/0 initialFrameWait/connectionFailed ile başarısız; sağlayıcı süreç canlı gözlendi. Fullscreen ve schema-2 density/relative pointer/wheel yazılımı root81Flutter/analyze, actual dual-ABI paket ve90native test/AndroidTest derleme kapılarını geçti. Ses/mikrofon/SAF/Gateway yazılımı ve strict runtime kabulü açık. [Doğrulanmış sonuç](testing/f62-42be-provider-failure-2026-10-01.md) |
| **Aktif final** | **FINAL.FUNCTION** | Exact721 geniş36832137026 tamamlandı: dört Server shardı, Flutter/static/aggregate, emulator/native/APK/host yeşil; eski F08 leaf observer ve Server aggregate başarısız. Değişmiş [exacta8 F08Linux36835138089](https://github.com/ersingundem/larenor/actions/runs/36835138089) gerçek CoreUID IPC/cgroup kapısını geçti. Security721 üç işi geçti. Final birleşik HEAD ve strict F60/F62 kabulü açık |
| **Bağımlılık bekliyor** | **FINAL.UI → FINAL.AUDIT → FINAL.CI → FINAL.GALLERY → FINAL.README → CORE.WEB** | Her adım önceki final tamamlandıktan sonra başlar; aynı anda ikinci FINAL alınmaz |

“CI bekliyor” geliştirme ve odaklı doğrulamanın bittiğini gösterir; tam kabul sayacını artırmaz. F27’de yeni bulunan çıkış-temizliği yarışı 243cc694 ile kapandı: root49 birleşik test, scoped analiz ve bağımsız inceleme geçti. F27 tekrar CI bekliyor; kalıcı I/O hatası pending kalır ve başarı iddia edilmez. Fiziksel cihaz, gerçek ev servisi/hesabı ve donanım kapıları MANUAL kayıtlarında kalır. [Core web UI teslim sırası](core-web-ui-delivery-plan-2026-09-30.md).

[F27 temizliği](testing/f27-authoritative-retirement-idempotency-2026-10-01.md), [F60 yerel kapanış](testing/f60-uncertain-session-local-close-2026-10-01.md).


3 Ekim RDP schema-2 dilimi: gerçek desktop/device yüzde-scale alanları, peer DISP CAPS sonrası tek initial layout, exact ACKed-frame giriş, resize/ACK eşzamanlılık çitleri ve aynı route üzerinde gerçek fullscreen yüzey sahipliği tamamlandı. Root tüm RDP Flutter testlerini **81/81**, analizini temiz; receipted iki ABI paketi ve actual native/Moonlight gate'ini **90/90** (0 skip/failure/error), AndroidTest derlemesini doğruladı. Paket/runner/owned-fixture portatif kapıları **106 test/83 subtest** geçti. Bunlar yerel yazılım kanıtıdır; eski42be hatasının kesin kök nedeni veya hosted runtime kabulü iddia edilmez. F62 yeniden çalışılıyor ve kabul sayaçları değişmedi. [Dart](testing/f62-dart-display-pointer-v2-2026-10-01.md), [native](testing/f62-native-display-pointer-v2-2026-10-01.md), [gerçek paket](testing/f62-display-pointer-package-2026-10-01.md), [owned fixture v2](testing/f62-v2-owned-initial-display-2026-10-03.md).

F60 gerçek Game surface/stage/connection callback sınırları artık exact lease token ile yalnız altı boolean olarak kaydediliyor. Geçerli yetki/oturum/revision çitleri, terminal/successor izolasyonu ve değişmeyen foreground kabulü root **46 JVM testi**, actual AndroidTest derlemesi, **54 runner/36 subtest +10 workflow/12 subtest** ile geçti. Tanı yalnız original failure kapısından yayımlanır; frame/PCM/input kabulü yerine sayılmaz. Değişmiş kaynak strict koşusu gerekli. [Bağlantı sınırı](testing/f60-owned-connection-boundaries-2026-10-03.md).

## Tarihsel düzeltme ve koşu checkpointleri

Aşağıdaki sayaçlar ve “sürüyor/düzeltiliyor” ifadeleri kendi kaynaklarının tarihsel durumudur; güncel durum yukarıdaki tablo ve execution queue'dur.

F60 exact `691b54c4` [36825268673](https://github.com/ersingundem/larenor/actions/runs/36825268673) başarısız tamamlandı. Root original **1test/1failure/0error/0skip** ve source/package/named identity ile canonical **1377byte** artifact **11145646517** kaydını production validatorla doğruladı: `firstStreamOutput`, `beforeIssue`, allowlist `java.lang.IllegalArgumentException`, runtimeFailure `none`, komut unknown ve lease absentOrUnreadable. Böylece izin oluşmadan önceki guard yolu daraldı; hangi guardın düştüğü henüz kanıtlanmadı. Bağımsız normal-route incelemesi belirsiz stream sonucunda ekrandaki Stop eyleminin kapalı kaldığını gösterdi; exact yerel retirement eylemi odaklı düzeltmeye alındı. F60 yeniden çalışılıyor; kabul sayacı değişmez. [Dar tanı](testing/native-strict-57f-failure-triage-2026-10-01.md).

FINAL.FUNCTION kabul tablosu, üretim özellik matrisi ve runtime envanterinin güncel bölümleri kuyrukla eşleştirildi: **69 iş/58 seçili özellik CI bekliyor**, yalnız **F60/F62 yeniden çalışılıyor**, kabul **35/127 ve3/63**. Önceki sayaç ve koşu kayıtları tarihsel eklerde korundu. Exact `1916395b` [geniş koşu36826527140](https://github.com/ersingundem/larenor/actions/runs/36826527140) başladı; aynı kaynak [Security36826516434](https://github.com/ersingundem/larenor/actions/runs/36826516434) üç işi geçti. Geniş koşu actual required-native paketleri doğrular; standalone strict stream/RDP runtime kapılarının yerine geçmez. [Güncel kabul tablosu](testing/final-function-acceptance-2026-09-30.md).

F62 test gövdesinin ilk satırından başlayan source-locked tanı, sabit lifecycle aşaması ve allowlist hata sınıfı dışında provider/credential/message saklamaz. Root **57 kontrol ve40subtest**, actual required-native AndroidTest **277 task** derlemesi ve bağımsız inceleme geçti. Exact `6bbe8b03` [yeni owned RDP koşusu](https://github.com/ersingundem/larenor/actions/runs/36826438225) başladı; TLS/NLA/SPKI/frame/ACK/key/DISP/Unicode/iki yaşam/kapanış kabulü gevşetilmedi. F62 yeniden çalışılıyor; gerçek runtime kabulü henüz yok. [Tanı sınırları](testing/f62-test-body-failure-diagnostics-2026-10-01.md).

F21/F24–F27 normal verified-Core katalogdan açık “Bu cihazda oynat” girişine, gerçek player kontrollerine ve Core kapalıyken tamamlanmış şifreli indirmelere bağlandı. Kalite danışmanı izin kotasını tüketmeyen `assess-item` kullanır; explicit Play için consumable `observe-item` korunur. Root son birleşik **110 Client** ve **46 Server** testini geçti; plan/kaynak incelemesinde yazılım bileşimi açığı kalmadı. Bu beş iş **CI bekliyor** tablosuna taşındı, kabul sayacı artırılmadı. [Kaynak, test ve sınırlar](testing/media-core-composition-closure-2026-10-01.md).

Exact `a51c8006` [tüm Server CI](https://github.com/ersingundem/larenor/actions/runs/36823315743) tamamlandı ve geçti: dört test shardı, kurulu host-worker ve Linux cgroup kapıları yeşil. Bu sonuç owned Frigate fixture düzeltmesinin değişmiş kaynak kabulüdür; eski503 hatasının kesin alt nedenini veya daha sonra eklenen medya kodunun geniş kabulünü kanıtlamaz. Kuyruk güncellemesinin exact `e09b51de` [Security CI](https://github.com/ersingundem/larenor/actions/runs/36825781068) secret/dependency/platform-policy üç işini geçti. Son birleşik kaynak için Android/tüm Server ve strict F60/F62 kapıları açık kalır;69/58 CI bekleyen ve35/127,3/63 kabul sayaçları değişmedi.

Yeni geniş [Android/tüm Server koşusu](https://github.com/ersingundem/larenor/actions/runs/36816909489) exact `5325c083` üzerinde başarısız tamamlandı; son kaynak [Security](https://github.com/ersingundem/larenor/actions/runs/36816859672) kabulünü geçti. Flutter shard0 K07 deadline yarışı, F08 eski stress observer ve üç Server shardındaki dokuz backup/arşiv test hatası mevcut. Bunlar yeni kaynak için geniş kabul değildir; dar neden incelemesi sürüyor. [Pinned Sunshine/Moonlight sözleşme araştırması](testing/f60-upstream-pairing-contract-review-2026-10-01.md) provider API/name/PIN uyumunu doğruladı; runtime stream yerine sayılmaz.

F42/F44 test bileşimi gerçek FFmpeg/FFprobe çiftini CI’da kurup doğrular; iki F42 fixture’ındaki Homebrew-only yollar kaldırıldı. Root 31/31 gerçek media decode/filter ve 3 workflow testi, actionlint ve 71 ilgili politika/kuyruk/progress kontrolü geçti. İkisi **CI bekliyor**; yeni Ubuntu kabulü gerekli, eski F44 503 tek nedeni kanıtlanmadı. [Dar kanıt](testing/f42-f44-linux-media-runtime-2026-10-01.md).

F08 AI worker listener kapanışı bounded accept polling ve exact listener sahipliğiyle düzeltildi; emekli thread yeni listenerı devralamaz veya kabul edilen eski stream’i işleme gönderemez. Root 12 passed/1 explicit Linux user-manager skip geçti. **CI bekliyor**; sonraki exact0c63f7d1 scoped Linux koşusu aşağıda kaydedildi. [Mekanizma ve sınırlar](testing/f08-worker-listener-close-2026-10-01.md).

F30 medya arşivi artık elapsed EOF/parser hatasını aynı monotonic süre sınırında doğru şekilde sınıflandırır; erken EOF hâlâ protokol hatasıdır. Aynı yazma isteği tekrarlanmaz. Gerçek owned loopback RED→GREEN ve root 10/10 transport testi geçti; **CI bekliyor**. [Dar kanıt](testing/media-archive-deadline-eof-2026-10-01.md).

Backup power-loss fixture’ının yalnız kesilmiş restore/recovery işlemlerindeki süre sınırı 8’den 30 saniyeye çıkarıldı. Hosted committed vaka 8,476 saniye sürdü; süre aşımı güçlü çıkarım, redacted asıl exception nedeniyle kesin kök neden değildir. Dört power-loss ve iki yetkisiz pause vakası root kabulünü geçti; production restore motoru ve kabul kriterleri değiştirilmedi. [Dar kanıt ve sınırlar](testing/backup-committed-recovery-2026-10-01.md). Yeni Linux CI sonucu gerekli.

F60 PIN bridge artık kabul edilen bağlantı, peer doğrulaması, okuma ve parse sınırlarını gizli değer içermeyen ayrı durumlarla kaydeder. Terminal bridge hatası yaşayan owned Gradle alt süreci bounded TERM/KILL ile kapatılıp toplanır; bitmiş Gradle sonucu korunur. Root 60 stream/discovery ve 10 workflow testi geçti. Strict tek named test, gerçek frame/PCM/input/iki yaşam/kapanış kapıları değişmedi; F60 **yeniden çalışılıyor**, yeni kaynaklı hosted kabul açık. [Dar kanıt](testing/f60-pin-transport-observation-2026-10-01.md).

- **Tam Flutter:** 7.919 passed/57explicit opt-in skip/0failure, terminal machine done.success=true; tam analyze temiz,1.981 Dart dosyası format değişikliği yok. Hidden loading sayılmaz; skipped normal-Core/SSH runnerları ve Kotlin/native/CI kabulü ayrı. [Kaynak ve sınırlar](testing/final-function-flutter-regression-2026-10-01.md).
- F14 gerçek Client/normal Core TCP aynı DB restart iki süreç kabulü1+1 ve root11/11 Client testi geçti. Kalıcı oturum/olay kapasitesi ayrıca root9/9 live-source kabulüyle kapandı. [Client/Core](testing/f14-normal-core-acceptance-2026-10-01.md), [retention](testing/f14-support-session-retention-2026-10-01.md).
- F01/F02/F03 root22/22: default256taslak/128deneme ve signed4096olay fixture kapasitesi restart sonrası toparlanır. Current/live/recent replay, encrypted rules, tamper/child graph ve rollback korunur. [Kanıt](testing/f01-f03-automation-retention-2026-10-01.md).
- F58 root18/18: default2000 signed hazırlık geçmişi ve normal Core restart; owned HA/OEPL HTTP send/dry-run geçti. Pending/uncertain/current render ACK korunur; fiziksel ekran teslimi iddiası yok. [Kanıt](testing/f58-authenticated-retention-2026-10-01.md).
- **F59 root28/28:** default10000 signed geçmiş sonrası restart/new confirm kapasitesi toparlanır. Current/inclusive24h/replay/unknown effects, tamper ve rollback korunur. Owned OctoPrint/Moonraker HTTP kabulü geçti;10000 fiziksel yazıcı komutu iddiası yok. **CI bekliyor**. [Kanıt](testing/f59-workshop-intent-retention-2026-10-01.md).
- **F57 root30/30:** gerçek256kapasite/restart, v1migration-time inclusive24h, current/recent replay, newest32terminal ve uncertain koruması geçti. Parent/cipher tamper ve write rollback reddi korunur. Advisory/localcalibration; fiziksel mmWave reconfiguration iddiası yok. **CI bekliyor**. [Kanıt](testing/f57-calibration-retention-2026-10-01.md).
- F50root33/33 kapasite/restart; F57/F58root21/21 sahipli confirmation dialog production-route kabulü önceki kanıttır. F57’nin yeni retention açığı ayrıca root30/30 ile kapandı; eski route kanıtı tek başına retention kabulü değildir.
- Normal product APK source/receipt/API bağlı gerçek Moonlight embed-v3+FreeRDP motorlarını aynı iki-ABI dağıtıma alır. Güncel actual required-mode debug APK SHA256 `0294d421…`; tüm 5 root verifier ve geniş JVM **343 passed/2 explicit opt-in skip/0 failure/0 error** geçti. Önceki v2 paket ve 338 JVM kaydı tarihsel kanıttır. [Actual build](testing/product-android-dual-native-actual-build-2026-10-01.md).
- Eski fecc Android koşusunda Server nested scope atlandı; defaultall düzeltmesi10/10 ve actionlint geçti. Format hatası iki Dart testinde düzeltildi. MQTT fixture TLS teardown ve legacy qualifiedlabel regresyonları root7passed+1explicit runner-onlyskip/scoped analyze/format geçti. [Flutter düzeltmeleri](testing/k09-mqtt-retired-transport-fixture-2026-10-01.md). Değişmiş son HEAD için yeni geniş koşu gerekir; eski fecc Security başarısı bütün CI yerine sayılmaz.

F22/F35 için sessiz hostta exact continuous-execution/access-expiry testi ve iki gerçek PDF/OCR HTTP testi geçti. Kaynak veya süre sınırı değiştirilmedi; işler yeniden **CI bekliyor** tablosunda. Yerel geniş Server koşusu disk dolunca yaklaşık %80’te durduruldu, dolayısıyla geniş kabul kanıtı değildir. Eski hataların tek nedeni kesinleşmedi. [Sınıflandırma ve dar kanıt](testing/server-quiet-regression-classification-2026-10-01.md).

FreeRDP iki-ABI CI paketleme kusuru ayrı kaynak ağaçlarıyla kapatıldı. Root iki gerçek AAR’ın yalnız kendi ABI’sini içerdiğini, ortak classes.jar karmasını ve birleşik product verifier sonucunu doğruladı; 5 workflow/package testi ve actionlint geçti. [Dar paket kanıtı](testing/product-freerdp-abi-isolation-2026-10-01.md). Worker callback/encoder ZIP paketlerinin umask077 altında yanlış modda üretilmesi de dar gerçek paket testleriyle düzeltildi. [İzin kanıtı](testing/host-worker-plugin-artifact-mode-2026-10-01.md). Değişen kaynak için hosted kabul gerekli.

Security `81cd4172` ve `70ab1058` kaynaklarında üç işi de geçti. F62 erken/live tanı düzeltmesi `70ab1058` root51, AndroidTest derlemesi ve bağımsız inceleme geçti; [strict native koşusu](https://github.com/ersingundem/larenor/actions/runs/36814807367) ilk kare bekleyişinde başarısız tamamlandı; kaynak incelemesi sürüyor. Tanı ve paket kanıtı gerçek RDP/stream kabulü yerine sayılmaz.

F08 exact `5325c083` geniş CI’da UID IPC testini geçti; stress testi `memory.events` errno2 ile başarısız. Üretim limitlerini değiştirmeyen [observer koordinasyonu](testing/f08-cgroup-observer-coordination-2026-10-01.md) root31passed/2explicitLinux skip ile doğrulandı; exact0c63f7d1 [36818355490](https://github.com/ersingundem/larenor/actions/runs/36818355490) Linux UID IPC/cgroup işi root exactSHA denetimiyle geçti. Bu scoped kabul, geniş final HEAD yerine sayılmaz; F08 CI bekliyor. F60 yeni [okuma aşaması tanısı](testing/f60-pin-read-rejection-2026-10-01.md) kesin EOF/deadline nedenini henüz ayırmıyor; yeniden çalışılıyor. Aynı geniş CI’ın Flutter shard0’ındaki native tablet komut deadline expected failed/actual denied yarışı [tek deadline düzeltmesiyle](testing/k07-native-command-one-deadline-2026-10-01.md) deterministic RED→GREEN geçti; root17test/analyze kabulü var, değişen kaynak için yeni CI gerekli.

K07’nin yeni native komut regresyonu düzeltildi ve 17 dar test/analyze geçti. Değişen kaynak henüz geniş CI kabulü almadığı için K07 ve ona bağlı K08 önceki done durumundan CI bekliyor durumuna alındı; eski exact kabul kanıtları tarihsel kaldı. Güncel tam kabul 35/127 (%27,6); seçili özellikler 3/63 (%4,8).

F60 owned PIN teslimi artık canonical parse sonrası nonsecret ACK ve EOF ister; root56 runner/workflow testi ve iki native motor zorunlu actual AndroidTest derlemesi geçti. Strict stream kabulü hâlâ açık; F60 yeniden çalışılıyor. [Dar sınır](testing/f60-pin-peer-ack-2026-10-01.md).

F62 ilk kare bekleyişi artık değişmeyen30sn sınırında bounded polling, exact throwable sınıfı ve optional nonce-bound private ölçülerle terminal/no-callback/yanlış-boyut/stall sınırlarını ayırır. Root43runner testi ve actual required-native AndroidTest derlemesi geçti; gerçek RDP runtime kabulü açık, yeniden çalışılıyor. [Dar sınır](testing/f62-initial-frame-wait-diagnostics-2026-10-01.md).

F30 geniş CI’daki7archive verifier/encoder/engine hatası için positive gerçek media fixture range/colorspace açık tanımlandı; üretim equality/hash/decode/durable kabulü değiştirilmedi. Root37gerçek FFmpeg testi,3workflow/11subtest/actionlint geçti. Exact `0fef589b0228049a119821d4e97af8b7c080e888` [Ubuntu36819883119](https://github.com/ersingundem/larenor/actions/runs/36819883119) başarılı; root exactSHA ve JUnit37test/0failure/0error/0skip kaydını doğruladı. Geniş finalHEAD CI hâlâ gerekli; F30 CI bekliyor. [Sınırlar](testing/f30-explicit-color-fixture-2026-10-01.md).

F60/F62 exact `57f929459a22ab6082e400194e31e0162545f672` [stream36819571890](https://github.com/ersingundem/larenor/actions/runs/36819571890) ve [RDP36819574142](https://github.com/ersingundem/larenor/actions/runs/36819574142) koşuları başarısız tamamlandı. Root exact kaynak, tek named test, 1/1/0/0 sayaçları ve private artifact JSON hashlerini doğruladı. F60 pairing sonrasındaki stream sonucu assertionında, F62 ilk kare öncesi terminal oturumda düşüyor; yayımlanan kanıt kesin provider/native alt nedenini vermiyor. [Dar tanı ve sınırlar](testing/native-strict-57f-failure-triage-2026-10-01.md). İkisi yeniden çalışılıyor;64iş/53seçiliözellik CI bekliyor ve35/127,3/63 kabul sayaçları korunur.

Backup test sunucusunun verified stream bekleme sınırı son yetki kontrolünü kapsayacak şekilde ayrıldı; deliberate post-effect gecikmesi, freshGET ve tekPOST/no replay kabulü korunur. Eski1sfixture deterministicRED, root iki hosted failure node2/2GREEN; production sınırları değişmedi. Yeni Linux kabulü gerekli. [Dar kanıt](testing/backup-effect-timeout-fixture-2026-10-01.md).

F26/F27 Core PlaybackInfo→single-use observation→original-byte lease backend bağlantısı root64provider/IPC/API testiyle geçti. Bildirilmemiş transcode decoderı, consuming-lock TTL yarışı ve kapasitede gözlem kaybı5RED→GREEN ile kapandı. Player kontrolleri/ortak izleme ownership ve offlinecold-start eksikleri açık olduğundan F21/F24–F27 yeniden çalışılıyor; tam kabul sayacı artmaz. [Backend kanıtı](testing/f26-core-playback-info-observation-2026-10-01.md).

F27 token-free yerel medya scope'u root **62 hesap/context testi** ve scoped analizden geçti; offline başlangıçta cached token API oturumu olarak kullanılmaz. Gerçek offline inventory/player navigasyonu tamamlanıyor; F27 yeniden çalışılıyor. [Hesap sınırı](testing/f27-offline-account-local-scope-2026-10-01.md). Backend ve backup [tüm Server CI](https://github.com/ersingundem/larenor/actions/runs/36820807607), exact `0659ac292acae05a458550f33b142c1b2100ea2d` üzerinde tamamlandı: host/F08 ve üç shard geçti; shard0 tek F44 kaynak bağlama503 ile başarısız (1.823 passed/1 failed). İptal kontrolüne henüz ulaşılmadı. Owned Frigate fixture’ın erken WebSocket kapanışı root18+31 testle düzeltildi; eski503 kesin nedeni olarak sunulmaz. [Dar kanıt](testing/f44-frigate-fixture-close-2026-10-01.md). Değişen exact `a51c8006c73aa9dfceaf0c4255d52943d0a79098` [tüm Server koşusu](https://github.com/ersingundem/larenor/actions/runs/36823315743) sürüyor; bu kaynak daha sonraki Client değişikliklerinin kabulü değildir.

Yeni F60 [command observation](testing/f60-stream-command-observation-2026-10-01.md) ve F62 [initial terminal classification](testing/f62-initial-terminal-classification-2026-10-01.md) yalnız sabit, gizli değer içermeyen ve exact owned source’a bağlı tanı alanları ekler. Yeni kaynaklı CI sonuçları gelene kadar ikisi yeniden çalışılıyor kalır; strict kabul gevşetilmedi.

## Tarihsel doğrulama kayıtları

Aşağıdaki kayıtlar ilgili commit ve koşunun o andaki durumunu korur; eski “bekliyor”, “açık” veya “henüz geçmedi” ifadeleri güncel durum değildir. Güncel sınıflandırma yukarıdaki tablo ve [execution queue](EXECUTION_QUEUE.md) kaynağıdır.

### 1 Ekim önceki koşu gözlemleri

Aşağıdaki sıralı gözlemler tarihsel durumu korur; güncel sınıflandırma üstteki tablodur.

F60 PIN teslim düzeltmesi eski failureın kesin alt nedeni olarak sunulmaz; kaynakta kanıtlanan swallow/dispatch yolu kapatıldı. [Kaynak ve tanı kabulü](testing/f60-pin-delivery-pairing-stage-2026-10-01.md).

F60 exact36cbe3a1 / [run36811116354](https://github.com/ersingundem/larenor/actions/runs/36811116354) **başarısız tamamlandı**: embed-v2 original1test/1failure/0error/0skip, pairingRegistration90s timeout; PIN bridge `listening` parse öncesi sınırdır, reverse/EOF alt nedenini kanıtlamaz. Gerçek stream receipt yok. Bu eski motor koşusu yeni embed-v3 düzeltmesinin kabulü değildir.

[Wellbeing manifest düzeltmesi](testing/wellbeing-product-manifest-regression-2026-10-01.md) root geniş JVM ile doğrulandı. [F60 üretim iptal düzeltmesi](testing/f60-pairing-cancellation-2026-10-01.md) embed-v3 exact Call.cancel, monotonic deadline ve successor ownership ile **40native/0skip + root63tool** kontrolünü geçti. Güncel actual product APK root5verifier ile doğrulandı; geniş required-package JVM345total=343passed/2opt-in skip/0failure ve birleşik root165tool kapısı geçti. Newline/EOF fixture açığı gerçek open-socket RED→GREEN ile kapandı. Yeni strict Sunshine CI kabulü gerekli.

[F62 yaşam döngüsü tanısı](testing/f62-owned-lifecycle-diagnostics-2026-10-01.md) root34/34 ve actual required-package AndroidTest derlemesiyle doğrulandı. Exact `c8291061` [koşusunun](https://github.com/ersingundem/larenor/actions/runs/36811909218) kanonik makbuzu **1 test/1 failure/0 error/0 skip**, unclassified/no owned frames ve **lifecycle stage yok** sonucunu içeriyor. serverResizeRequested=false; arm64 package geçti. Eski initial-frame/resize hatası veya app crash kesin neden sayılmaz. Gradle sonrasında okuma bu nedenleri ayırt edemediği için çalışma sırasında tanı toplama hazırlanıyor; gerçek RDP kabulü açık.

Exact `36269cf05091156ae960106eaec27810ff35fc78` üzerinde [Android ve tüm Server CI](https://github.com/ersingundem/larenor/actions/runs/36813872693) sürüyor. [Security koşusu](https://github.com/ersingundem/larenor/actions/runs/36813874099) yeni bir failure ile tamamlandı ve dar incelemede. Bunlar CI kabulü değildir; 67 CI bekleyen iş ve 37/127, 3/63 tam kabul sayaçları değişmedi. Yerel tam Server koşusundaki F22/F35 hataları ayrıca inceleniyor.

Security failure kaynağı doğrulandı: 15 tam geçmiş fingerprint için yanlış pozitif istisnası hazırlandı; genel dosya/kural/commit istisnası yok. Root tam geçmiş taramasında 0 bulgu, yeni sentetik adayda engelleyici exit17 ve 23 politika testi geçti. [Kaynak ve kapsam](testing/security-exact-history-fingerprints-2026-10-01.md). Yeni hosted Security kabulü henüz yok.

F62 erken başlangıç ve Gradle kapanmadan enum toplama düzeltmesi root51 runner/workflow/dependency testinden ve actual required-native AndroidTest Kotlin derlemesinden geçti. Bağımsız incelemede bulunan in-flight okuma/kapanış yarışı RED→GREEN ile kapandı; orijinal strict RDP kabul kapıları korunur. Yeni kaynaklı hosted kabul gerekli. Geniş exact362 Android CI’ında FreeRDP iki-ABI paket adımı yeni failure verdi; dar inceleme sürüyor. Security düzeltmesi `81cd4172` pushlandı, [yeni koşu](https://github.com/ersingundem/larenor/actions/runs/36814632423) sürüyor. Bunlar tamamlanma sayaçlarını artırmaz.

Yeni kaynak `81cd4172` [Security koşusu](https://github.com/ersingundem/larenor/actions/runs/36814632423) secret/dependency/platform-policy üç işini de geçti. F22/F35 yeni yerel hataları nedeniyle CI bekleyen tablodan incelemeye geri alındı: **65 iş / 56 seçili özellik CI bekliyor**, tam kabul 37/127 ve 3/63 değişmedi. Aynı kaynak körlemesine yeniden çalıştırılmıyor.

### 1 Ekim F62 Linux fixture configure sınırı

Düzeltme commit’i **1d1ccf2e** aynı dala pushlandı; [native gate36805226494](https://github.com/ersingundem/larenor/actions/runs/36805226494) exact kaynak SHA ile başladı. Runtime receipt henüz yok; yerel kontroller bu commit’in test kanıtıdır, hosted kabul değildir.

Exact8d54993f [native36804331620](https://github.com/ersingundem/larenor/actions/runs/36804331620) x86 işi **configure_failed** ile derleme/Android/runtime öncesinde düştü; arm64 APK işi sürüyor. Private CMake logunun alt nedeni mevcut artifactlardan kurulamadı. Pinned kaynak Linux'ta Kerberos'u varsayılan açıp REQUIRED yapıyor; bu private SAM/NLA/NTLM fixture Kerberos kapsamı vaat etmediği için yeni ayar açıkça **WITH_KRB5=OFF** kullanır. Bu portability düzeltmesi eski koşunun kesin hata nedeni olarak sunulmaz; TLS/NLA/SAM/SPKI kapıları korunur.

Yeni helper yalnız failed configure/build için exact source/patch/log hash bağlı bounded failure JSON yayımlar; actual fatal CMake blocktan fixed reason ve allowlisted relative path/line çıkarır, raw mesaj/env/option/absolute path yayımlamaz. Optional missing dependency mesajı ilgisiz fatalı yanlış sınıflandıramaz. Diagnostic write hatası original failureı değiştirmez. Direct CLI PYTHONPATH unset ve başka cwd'de doğrulandı; **112 Python kontrolü**, exact archive verifier, workflow actionlint ve diff kontrolü geçti. Android runner başlamadan native rapor upload edilmiyor. [Kaynak ve tanı kanıtı](testing/f62-owned-shadow-channels-2026-10-01.md).

F60 eski cancelled-step koşusunun live concurrency lease'i kalktı; exacta703289d [retry36804692946](https://github.com/ersingundem/larenor/actions/runs/36804692946) gerçek hosted runnerda çalışıyor, UHID hazırlığı geçti ve engine derleniyor. Eski run GET'i stale olduğundan bilinmeyen final conclusiona kabul verilmez.58 seçili/toplam67 iş CI bekliyor; F60/F62 yeniden çalışılıyor ve37/127,3/63 kabul sayaçları korunur.

### 1 Ekim F60 gerçek Android keşif kabulü

Exact5fa91e43 [discovery36802851003](https://github.com/ersingundem/larenor/actions/runs/36802851003) yeşil tamamlandı. Root ve bağımsız ajan canonical public receiptin exact source/class/method, **1test/0skip/0failure/0error**, iki fresh discovery lifetime ve receipted Moonlight engine/source/package binding eşitliğini doğruladı. **streamAccepted=false**; bu gerçek NSD keşif kanıtıdır, yayın/girdi kabulü değildir. [Receipt ve sınırları](testing/f60-android-junit-aggregate-2026-10-01.md).

Same-source stream36802861944, emulator boot sonrası erken APK prebuild adımında cancelled oldu; named instrumentation/test/receipt veya provider failure code yok, cleanup geçti. GitHub terminal run conclusion henüz vermediği için kuyruk bu metadata sınırını açıkça kaydeder; cancellationın external nedeni kanıtsızdır. F60 yeniden çalışılıyor kalır. F62 yeni gerçek Unicode/CLIPRDR/DISP kaynak commit'i **8d54993f** pushlandı ve [native gate36804331620](https://github.com/ersingundem/larenor/actions/runs/36804331620) exact SHA ile başladı. x86 fixture build hazırlığı Android/runtime öncesinde başarısız oldu; arm64 paket işi sürüyor ve dar neden inceleniyor. Tamamlanan **58 seçili/toplam67 iş CI bekliyor**; tam kabul **37/127** ve **3/63** değişmedi.

### 1 Ekim F62 gerçek Unicode paketi ve owned kanal kabulü

Exactd69cb0bd [native koşusu36801363639](https://github.com/ersingundem/larenor/actions/runs/36801363639), original1test/1failure/0error/0skip ile **resizedFrameWait** aşamasında başarısız tamamlandı; arm64 paket işi geçti. Yeni gerçek post-resize frame/ACK/close kabulü gerekir. JNI modified UTF8 sınırındaki emoji hatası pinned FreeRDP/Android kaynaklarıyla doğrulandı; UTF16→standard UTF8 düzeltmesi, NUL/surrogate/64KiB sınırları ve payload silme yeni engine identity/receipt ile bağlıdır. Root exact source ve iki reviewed patch ile gerçek x86_64 AARı yeniden derledi, receipt/verify-install geçti; yeni paketle app ve AndroidTest Kotlin derlemesi ile **24 RDP unit/0skip/0failure/0error** geçti. **105 Python kontrolü**, workflow actionlint ve diff kontrolü de yeşil. [Paket ve derleme kanıtı](testing/f62-native-clipboard-unicode-2026-10-01.md).

Owned Linux shadow artık aynı pinned kaynaktan CLIPRDR/DISP destekli CLI olarak hazırlanır; Android tek named testte iki gerçek authenticated lifetime ister. İlkinde actual DISP→host resize→frame/ACK ve Türkçe/emoji/LF/tab metninin gerçek UTF16 remote etkisi, ikincide clipboard kapalı/zero transfer doğrulanır. Kaynak/patch/binary ve private terminal witness bağlıdır; `serverResizeRequested` yalnız sabit boolean olarak kalan resize hatasını ayırır. Linux fixture derlemesi ve iki gerçek Android lifetime hosted gate'i **henüz geçmedi**. F62 yeniden çalışılıyor kalır; tamamlanan58 seçili/toplam67 iş CI bekliyor,37/127 ve3/63 tam kabul sayaçları korunur. [Fixture](testing/f62-owned-shadow-channels-2026-10-01.md), [gerçek kabul sınırı](testing/f62-owned-channel-acceptance-2026-10-01.md).

### 1 Ekim tamamlanan işlerin CI durum ayrımı

Geliştirme ve odaklı doğrulaması tamamlanan **58 seçili özellik / toplam 67 iş**, kuyruğun en alttaki tablosunda **CI bekliyor** olarak gösterilir. Bu durum son dal HEAD'inin geniş CI kabulünün beklendiğini belirtir; tam kabul sayacını artırmaz. Gerçek işlev eksikleri bulunan **F60 ve F62 yeniden çalışılıyor**, yalnız **FINAL.FUNCTION** aktif final adımıdır. Kuyruk kaynağı, görünümü ve sayaçları doğrulandı; 26 kuyruk testi geçti. Kanıtla kabul edilen sayaçlar **37/127** ve **3/63** olarak korunur.

Exact `d69cb0bdaecda35e5a7a927dc2f4cfd93ffe1a01` üzerinde [F60 discovery](https://github.com/ersingundem/larenor/actions/runs/36801358423), [F60 stream](https://github.com/ersingundem/larenor/actions/runs/36801361054) ve [F62 native](https://github.com/ersingundem/larenor/actions/runs/36801363639) başladı; üç kaynak SHA'sı bağımsız doğrulandı. F60 stream koşusu UHID ön kontrolünde `gamepadHostUnavailable` ile başarısız tamamlandı; engine/provider/instrumentation başlamadı ve receipt yok. Sabit tanı kernel modülü, cihaz ve kimlik kontrolünü ayırmadığından exact alt neden henüz kanıtlanmadı; dar tanı düzeltmesi hazırlanıyor, aynı SHA yeniden başlatılmıyor. Yeni dar kaynak tanısı modül yükleme, cihaz kimliği ve runner sınırlarını sabit nedenlerle ayırır; modül çıktısı gizli kalır, gerçek UHID/evdev/ACL etkisi zorunluluğu değişmez. Root116 ilgili test geçti; [tanı ve sınırlar](testing/f60-owned-uhid-preflight-2026-10-01.md). Sonraki exact sonuçlar ayrı kabul kayıtlarında izlenir. Bunlar henüz kabul sonucu değildir;58/67 CI bekliyor ve37/127,3/63 sayaçları değişmedi.

### 1 Ekim F60 gerçek ddmlib rapor şekli

Exactd69cb0bd discovery36801358423 gerçek400-task app/test APK buildi ve instrumentation Gradle başarıyla döndükten sonra `Android discovery report aggregate is invalid` ile receipt üretmeden düştü. Kullanılan ddmlib32.4.1 JAR SHA256 `ad7b49fc07ca341d205fb7eb17cd0610a18cd1678e55b6b4a869bbdee3fbf0e3` ve bytecode, `testsuites` dış wrapperını doğruladı. Shared discovery/stream parser artık outer+tek child suite için1test/0skip/0failure/0error eşitliğini ve exact class/method kimliğini birlikte ister; çoklu/nested suite, count drift, skipped/error/failure ve yabancı case reddedilir. Eski kaynak iki regresyonda RED, değişiklikte root107 kontrol GREEN; iki workflow actionlint geçti. Ham XML elde olmadığından eski koşuya sonradan kabul verilmez; yeni exact hosted receipt gerekli. [Kanıt ve sınırlar](testing/f60-android-junit-aggregate-2026-10-01.md).

### 1 Ekim F60 exact kernel modül hazırlığı

Exact `10cfb138` [stream36802066869](https://github.com/ersingundem/larenor/actions/runs/36802066869), UHID modül yüklemesinde `gamepadKernelModuleUnavailable` ile düştü; engine/provider/instrumentation başlamadı. CI hazırlığı artık modül metadata yoksa yalnız çalışan Azure kernel releaseine ait `linux-modules-extra` paketinin exact APT candidate sürümünü kurar, dpkg sürümü ve module vermagic eşitliğini doğrular. Kernel image/meta-package/reboot ve genel cihaz izni yok; gerçek UHID/evdev/etkili ACL/OSC etkisi kapıları değişmedi. Root29 workflow/gamepad testi ve actionlint geçti; yeni hosted sonuç açık. F60 yeniden çalışılıyor ve58/67 CI bekliyor,37/127,3/63 sayaçları korunur.

### 1 Ekim F60 gerçek APK derleme ve girdi kabul sınırı

Exact2af5e8cc discovery36799033298 ve stream36799039362, Flutter derlemesi atlandığı için `copyJniLibsflutterBuildDebug` girdisi bulunamayarak başarısız tamamlandı; Android kabul raporu/receipt yok. Ortak gerçek APK prebuild artık provider başlamadan Flutter JNI ve iki APK'yi oluşturur. Yerel tam derleme ikinci gerçek runner1.3.0/1.7.0 çakışmasını gösterdi; paketli Moonlight da mevcut debug constraint kapsamına alındı. Canonical AAR ile400-task tam APK derlemesi ve source-lock APK verifierı geçti. OSC→owned UHID/evdev gamepad etkisi yeni gate'e bağlıdır; yalnız gönderilmiş paket kabul sayılmaz. XI2 key readerın ilgisiz Motion satırıyla eski release'i tamamlayabildiği false-positive regresyonu da kapatıldı. Gerçek hosted sonuç ve fiziksel kapılar açık; F60 yeniden çalışılıyor,58/67 CI bekliyor ve37/127,3/63 kabul sayaçları korunur. [Derleme kanıtı](testing/f60-apk-prebuild-2026-10-01.md), [girdi sınırı](testing/f60-owned-input-disconnect-android-2026-10-01.md).

### 1 Ekim F62 gerçek rapor biçimine bağlı hata tanısı

Exact7fccce52/run36797967344 gerçek ilk frame/ACK/key ve owned1024×768 host resize adımlarını geçti; original1test/1failure/0error/0skip sonucunda resized frame/pixel/ACK veya teardown assertionı ayrışmadı. Mevcut bütün assertions korunarak beş sabit tanı sınıfı eklendi. Exact AGP9.4.1/ddmlib32.4.1 exporterının `failure@type` yazmadığı gerçek JAR bytecodeuyla doğrulandı; parser yalnız ilk exact throwable başlığı, original test kimliği/sayımı ve owned method framei eşleşince tanı yayımlar. Message injection ve yanlış kaynak/sayım reddedilir. Root27 parser testi, JAR hash/bytecode ve277-task receipted AndroidTest compile kaydını bağımsız doğruladı. Yeni kaynaklı hosted kabul gerekir; F62 yeniden çalışılıyor kalır. [Tanı kanıtı](testing/f62-post-resize-failure-diagnostics-2026-10-01.md).

### 1 Ekim RDP açık pano eylemi

RDP’nin tabletten uzağa pano modu artık gerçek Flutter→strict native→packaged FreeRDP gönderim yoluna bağlıdır. Okuma yalnız kullanıcının dokunuşuyla ve foreground/current oturumda yapılır; 64 KiB strict UTF8/NUL sınırı, ortak girdi sırası, byte silme ve geciken eski oturum yanıtının successor bağlantıya geçmemesi korunur. Okuma/gönderim beş saniyede sınırlıdır; doğrulanamayan gönderim exact eski kanalı kapatır ve otomatik tekrar yapmaz. EN/TR 2x erişilebilir UI dahil45 Flutter testi,15 native XML kontrolü/sıfır skip ve tam Flutter analyze geçti. Gönderim sonucu remote pano readbacki değildir; gerçek NLA/cliprdr etkisi hâlâ açık. [Client kabul sınırı](testing/f62-client-clipboard-submission-2026-10-01.md), [native kanıt](testing/f62-native-clipboard-bridge-2026-10-01.md).

Exact7fccce52 [RDP koşusu36797967344](https://github.com/ersingundem/larenor/actions/runs/36797967344) original1 test/1failure/0error/0skip ile başarısız tamamlandı. Gerçek keyboard witness ilk frame/ACK/girdi aşamasının geçildiğini, runner host çözünürlüğünün değiştiğini doğrular; hata sonraki resized-frame/ACK/close/credential sınırına daralır. Saklanan güvenli kanıt exact assertionı ayırmadığından sabit stage tanısı hazırlanıyor; aynı kaynak körlemesine yeniden çalıştırılmadı. F62 yeniden çalışılıyor,58 seçili/toplam67 iş CI bekliyor ve37/127,3/63 kabul sayaçları değişmedi. Yalnız FINAL.FUNCTION aktif kalır.

### 1 Ekim F60 gerçek sağlayıcı uyumluluğu ve açılış hatası

Exact `04552c724fd8a5f981a3f9f64986605f218604a1` üzerindeki [discovery koşusu](https://github.com/ersingundem/larenor/actions/runs/36792376426) receipted Moonlight buildini geçti, fakat Android emülatörü açılış zaman aşımına düştü. Python/NSD başlamadı; bu sonuç Sunshine bağlantı hatası veya keşif kabulü değildir. Private job tanısı KVM erişimi olmadığını ve `-accel off` kullanıldığını doğruladı. Workflowlar artık KVM character-device/read-write kontrolü ve açık hardware acceleration ister; desteklenen `swiftshader` seçimi ayrı uyumluluk düzeltmesidir. Değişen kaynakla yeni hosted kabul gereklidir.

Pinned [Moonlight](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/NvHTTP.java) `GET /unpair` kullanır; pinned [Sunshine NvHTTP](https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/nvhttp.cpp) bu rotayı sunmaz. Core/Dart `local_cleared` sözleşmesindeki Client metni, yerel kaldırma ile Sunshine güvenini kaldırmayı açıkça ayırır; Sunshine host eşlemesi kaldırılmış sayılmaz. Admin fixture temizliği ürün işleminin kanıtı olamaz. F60 yeniden çalışılıyor; **58 seçili özellik / toplam67 iş CI bekliyor**, kabul sayaçları **37/127** ve **3/63** olarak korunuyor.

Yerel kaldırma artık exact registration/pairing kaydını önce çitleyip siler; sonra ComputerDB yokluğunu ve causal readbacki doğrular. Authority değişimi, aktif oturum ve successor kayıt yeniden kullanımı kapalıdır; eski `revoked` journal sonucu yalnız `local_cleared` olarak okunur. Geçiş veya executor submission hatası geçici kilidi bırakır, kalıcı karantina/no-replay korunur. Root33 native test/0skip ve AndroidTest compile sonucunu bağımsız doğruladı; Client12 widget testi/scoped analyze geçti. Root95 araç/kuyruk/progress testi ve actionlint geçti. Named owned stream gate gerçek NSD/eşleme/katalog/frame/PCM/software key/stop ister, fakat receipt açıkça `featureAccepted=false`, `providerPairingRemoved=false` taşır. [Native](testing/f60-owned-sunshine-stream-android-2026-10-01.md), [Client](testing/f60-local-retirement-client-2026-10-01.md), [owned stream](testing/f60-sunshine-android-stream-2026-10-01.md).

F60 kapsam incelemesi plan/Client/Core sözleşmesini eşledi: ürün eylemi yalnız bu tabletten kaldırmadır ve Sunshine eşlemesinin kaldığını açıklar. Otomatik admin eşleme silme zorunlu kabul ölçütü değildir. Named gerçek stream ve yazılım touch/gamepad/beklenmeyen kopuş kabulü açık kaldığı için F60 yeniden çalışılıyor; fiziksel controller/gecikme MANUAL kapısında tutulur.

Exact `1887ff9a` [discovery](https://github.com/ersingundem/larenor/actions/runs/36797303341) ve [stream](https://github.com/ersingundem/larenor/actions/runs/36797304940) engine/KVM sonrasında `Android emulator identity is unavailable` ile düştü; private stream tanısı PATH'te bulunmayan `emulator` komutunu doğruladı. Shared probe artık exact yapılandırılmış SDK executable'ını kullanır; eski exact kaynak RED, düzeltme GREEN ve13 discovery regresyonu geçti. Provider/NSD/instrumentation/receipt kanıtı kurulmadı. [SDK düzeltmesi](testing/f60-emulator-sdk-identity-2026-10-01.md).

F60 yeni owned gate iki bağımsız stream yaşamı, gerçek Game touch/mouse→XI2 etkisi, exact Sunshine daemon kapanışı→ikinci lease `connectionTerminated`, no replay ve local retirement ister. Root doğru canonical AAR ile production/AndroidTest compile ve33 native/sıfır skip XML sonucunu doğruladı. Hosted iki-yaşam sonucu henüz yok; gamepad ve geniş CI de açık, bu yüzden F60 “CI bekliyor” yapılmadı. [Giriş/kopuş dilimi](testing/f60-owned-input-disconnect-android-2026-10-01.md).

Root birleşik105 F60 host/stream/discovery/workflow/kuyruk/progress kontrolünü geçti. XI2 pointer witness aynı dinleyicinin gördüğü owned X11 probeuyla gerçekten hazır olmadan Android girdi ACK'i vermez; probe hareketi girdi kanıtından temizlenir. Byte/line sınırı ve her EVENT sınırında sıfırlama, ilgisiz veya kesilmiş satırların eski olayı tamamlamasını engeller. Son tam Flutter analyze de temizdir; bu sonuçlar hosted receipt yerine sayılmaz.

Bu kaynak exact `2af5e8cc48c7cf52aa98172f6d5369337a8fa822` olarak pushlandı. [Yeni discovery](https://github.com/ersingundem/larenor/actions/runs/36799033298) ve [iki-yaşam stream/girdi/kopuş](https://github.com/ersingundem/larenor/actions/runs/36799039362) CI koşularının aynı SHA üzerinde başladığı bağımsız doğrulandı; henüz receipt yok. Kuyrukta yalnız gerçekten yazılımı ve odaklı doğrulaması biten58 seçili/toplam67 iş “CI bekliyor”, F60/F62 yeniden çalışılıyor ve37/127,3/63 kabul sayaçları korunuyor.

### 1 Ekim F62 dürüst yetenek ve authenticated output sınırı

Client artık exact pano modlarını taşır, unsupported legacy bidirectional seçimini sessizce değiştirmez, IME=false için alan sunmaz ve loaded external/default display değişiminde eski oturumu no replay ile kapatır. Credential’sız sertifika probeu login sonucu değildir; sabit Client NLA politikası ve credential zorunludur. Native sertifika callbacki yalnız exact endpoint/pin kabulünü kaydeder; güvenlik ve ilk kare gerçek OnConnectionSuccess sonrası sıralı açılır. TLS1.2 min/max enforce edilir. Root receipted FreeRDP AAR ile production/AndroidTest compile315 task ve22 native/0skip geçti;38 Flutter RDP testi ile scoped analyze temiz. Owned shadow gate gerçek software HID→XI2 effect, host resize, ACK ve close ister; Xvfb yerine tek aktif output ve iki gerçek modu doğrulayan Xorg dummy preflightı AAR buildinden önce çalışır,31 runner/workflow testi geçti; clipboard/IME/clientDISP veya fiziksel keyboard iddiası vermez. Exact e05df8ea/run36794954941 gerçek Linux Xorg display preflightı geçti; Android/shadow receipt ve exact display/clipboard kabulü açık: F62 yeniden çalışılıyor,58/67 CI bekliyor ve37/127,3/63 kabul sayaçları değişmedi. [Native](testing/f62-authenticated-output-boundary-2026-10-01.md), [Client](testing/f62-rdp-client-capability-truth-2026-10-01.md), [owned baseline](testing/f62-owned-shadow-baseline-2026-10-01.md).

Exact `e05df8ea` [RDP koşusu](https://github.com/ersingundem/larenor/actions/runs/36794954941) tamamlandı: Xorg ön kontrolü ve iki ABI APK buildi geçti; dış XI2 witness ilgisiz UTF8 device satırını strict ASCII çözerken düştü. Terminal JUnit sayımı yok; Android frame/key/resize/close kabulü kurulmadı. Eski kaynak üzerinde aynı regresyon RED, byte-parser düzeltmesi GREEN ve75 runner/workflow/kuyruk/progress kontrolü geçti; değişen kaynak hosted kabulü açık. F60 [discovery](https://github.com/ersingundem/larenor/actions/runs/36796250482) ve [stream/local retirement](https://github.com/ersingundem/larenor/actions/runs/36796253857) kapıları exact `0036260b` üzerinde engine/KVM geçti; `tool` modülü bulunamadığından provider workspace/NSD/instrumentation başlamadan düştü, receipt yok. Repo-root `python3 -B -m tool.<module>` çağrısı düzeltildi;54 F60 kontrolü ve iki workflow actionlint geçti. Bu dar düzeltme hosted özellik kabulü değildir; F60/F62 açık ve58/67 CI bekliyor sayacı korunur.

F62 display dilimi logical `displayId` ve process-local revision çitini tamamladı. Kaldırılmış/geçersiz Display, eksik tuple veya native stream kapanışı eski oturumu no replay ile kapatır; bağlantı/girdi kullanılamaz durumu görünürdür. Root49 Flutter RDP/window testi/sıfır skip ve13 native test/sıfır failure/error/skip XML sayımını doğruladı; production Kotlin compile ve scoped analyze geçti. Android’in fiziksel ekran kimliği veya teslim edilmeyen hotplug callbacki için kabul iddiası yok; gerçek hosted RDP/channel kapısı açık kalır.

### 1 Ekim F60 gerçek çıktı tanığı bağlantısı

Pinned Moonlight artık gerçek MediaCodec rendered-frame callbackini ve yalnız tam pozitif AudioTrack PCM write sonucunu exact visible/connected/not-stopping lease ile gözler. Private tanıklar1 ile sınırlıdır; Activity görünürlüğü, connectionStarted veya buffer release çıktı kanıtı sayılmaz. Fresh AAR/APK source-lock/link doğrulaması,29 Moonlight ve birleşik46 native test/0skip geçti; root7 paket testini, XML sayımlarını ve iki APK verifierını bağımsız doğruladı. Gerçek owned Sunshine frame/PCM gözlemi ve fiziksel ses/kalite kabulü açık; F60 yeniden çalışılıyor,58/67 CI bekliyor ve37/127,3/63 kabul sayaçları değişmedi. [Kanıt](testing/f60-moonlight-output-witness-2026-10-01.md).

### 1 Ekim F60 gerçek Sunshine host readiness kabulü

Exact768a511176136c00b8fef103105602e02178e311/run36791861104 gerçek owned Sunshine host readiness kapısını geçti. Root canonical741-byte receipt/source/package kimliğini ve SHA256905cee98d5eb0b5ef7546b86650fe47f8b07f03caab2aa46b5aee7bd33281507 doğruladı; state=host_ready ve streamAccepted=false. Aynı exact discovery run36791864541 native test başlamadan output_must_not_exist ile düştü: workflow builderın absent beklediği work dizinini önceden oluşturuyordu. Yalnız mkdir operandı kaldırıldı;7 focused discovery testi/actionlint geçti. Gerçek discovery/pairing/stream/frame/audio/input/stop/local retirement hâlâ açık, F60 yeniden çalışılıyor kalır. 58 seçili/toplam67 CI bekliyor ve37/127,3/63 kabul sayaçları korunur. [Kanıt](testing/f60-sunshine-owned-host-2026-10-01.md).

### 1 Ekim F60 normal Client/native entegrasyonu

Normal Core v2 grant/authority yolu gerçek Client eşleme, katalog, dispatch, causal stop ve revoke akışına bağlandı. Kalıcı cleanup storage hatasında bile native oturumu kapatır; yeni ekran clientInstanceId ile eski retirement kaydından ayrılır. Native45/45, Flutter86+1 beklenen skip, scoped analyze ve root gerçek normal Core TCP1/1 geçti. Receipted iki-ABI embedded APK ve motorsuz kapalı default APK doğrulandı; root80 host/paket/kuyruk/progress kapısını geçti. Owned Sunshine run36791191000 yine readiness receipt vermedi; resmî Avahi `--interface` de desteklemediği için seçenek kaldırılıp trusted interface parsable kayıtta filtrelendi. Root24 host testi geçti. Source/package-bound ve strict single-method/zero-skip production NSD gate hazır, fakat gerçek discovery/pairing/stream/frame/audio/input/stop/local retirement receipt açık. F60 yeniden çalışılıyor kalır; 58 seçili/toplam67 CI bekliyor ve37/127,3/63 kabul sayaçları değişmedi. [Entegrasyon kanıtı](testing/f60-moonlight-embedded-integration-2026-10-01.md), [Client](testing/f60-game-streaming-client-v2-2026-10-01.md), [owned host](testing/f60-sunshine-owned-host-2026-10-01.md).

### 1 Ekim F60 Avahi komut uyumluluğu

Run36790838898 exact525176a23 owned host adımında readiness receipt üretmeden düştü. Resmî Avahi seçenekleri Ubuntu executableın `--ipv4` desteklemediğini doğruladı; yalnız bu geçersiz argüman kaldırıldı. Exact interface, bounded stdout ve owned service name/type/domain/hostname/port kapıları korunur, farklı adres aileleri aynı exact kimlikte birleştirilir. Root22 host/dispatcher testi geçti. Değişen kaynakla hosted readiness hâlâ açık; F60 yeniden çalışılıyor, CI bekliyor ve kabul sayaçları değişmedi. [Kanıt](testing/f60-sunshine-owned-host-2026-10-01.md).

### 1 Ekim F60 gerçek host keşif düzeltmesi

Run36790356666 exactf8db9580 dispatcher/bağımlılık kurulumu geçti, fakat owned host mDNS gözleminde10sn sonra safe exit2 verdi; readiness receipt yok. Pinned Sunshine publisher mDNS instance için sunshine_name yerine runner hostname algoritmasını kullanıyor. Bounded Avahi stdout artık yalnız exact owned hostname/type/port resolved record ile kabul edilir; timeout tek başına başarı değildir. Root22 host/dispatcher ve47 policy testi geçti. Değişen kaynakla yeni hosted kabul gerekli; F60 yeniden çalışılıyor ve sayaçlar değişmedi. [Kanıt](testing/f60-sunshine-owned-host-2026-10-01.md).

### 1 Ekim F60 izole gerçek Sunshine host hazırlığı

Owned host harness yalnız GitHub-hosted Ubuntu24.04te pinned Sunshine paketini hash/sürüm readback ile kurar; private TLS, Xvfb/PulseAudio readiness ve exact mDNS gözlemi sağlar. Pair/unpair APIleri yalnız exact owned kimliklere sınırlıdır; gizli materyal yayımlanmaz ve owned süreçler temizlenir. Root 47 host/policy testi geçti. Yeni workflow doğrudan GitHub404 verdiği için kayıtlı server-test dispatchera ayrı f60-host same-commit çağrısı eklendi; yanlış caller/contract/ref/SHA reddedilir. Root19 host/dispatcher ve47 policy testi/actionlint geçti. Hosted smoke henüz çalışmadı; receipt açıkça host_ready/streamAccepted=false verir. Bu hazırlık gerçek Android eşleme/yayın/girdi/stop/revoke kabulü değildir: F60 yeniden çalışılıyor, 58 seçili/toplam67 CI bekliyor ve37/127,3/63 kabul sayaçları değişmedi. [Kanıt](testing/f60-sunshine-owned-host-2026-10-01.md).

### 1 Ekim F62 gerçek frame ACK yarışı düzeltmesi

Exact7f673d55/run36789173329 gerçek TLS/NLA/SPKI ve nonzero1280×800 ilk framei geçti; original named1test/0skip safe tanı ilk ACK satır120yi belirledi. Native ACK eski buffer serbest kalmadan yeni callbacke izin veriyordu; exact pending sequence artık consumer resume sonuna kadar korunur. Disconnect sırasında ACK terminal oturumu yeniden ACTIVE yapamaz. Root eski davranışta2 RED regresyonu üretti; düzeltmede14/14 native/0skip ve receipt-verified AAR ile production/AndroidTest compile (314 task) geçti. Capability review IME/bidirectional clipboard iddiası ve stale display snapshot eksikleri buldu; F62 yeniden çalışılıyor kalır. Yeni actual host acceptance gerekli;58 seçili/toplam67 CI bekliyor ve37/127,3/63 kabul sayaçları değişmedi. [Kanıt](testing/f62-frame-ack-lifecycle-2026-10-01.md).

### 1 Ekim F62 canonical SPKI düzeltmesi

Exact1259f39e/run36786452264 safe receipt original method/1test/0skip/1failure/0error ile JNI URI ve gerçek TLS sertifika inspect adımlarının geçtiğini, strict request SPKI biçiminde düştüğünü gösterdi. Encoderın trailing `=` dolgusu kaldırıldı; değişmeyen 50-karakter contract original instrumentationda da kontrol edilir. Root receipted AAR ile production/instrumentation Kotlin compile (315 task) ve7 NativeContract testi/0skip/0failure/0error geçti. Yeni exact gerçek NLA/frame/input/resize/clipboard/close kabulü açık: F62 test bekliyor, 58 seçili/toplam67 CI bekliyor ve37/127,3/63 kabul sayaçları değişmedi. [Kanıt](testing/f62-canonical-spki-pin-2026-10-01.md).

### 1 Ekim F61 gerçek TigerVNC kabulü

Run36783304533 exactf83deee786ef0ce4f47a9beccbb6c3f0ed8bdea7 yeşil tamamlandı. Root canonical receipt source/class/method/1test/0skip/0failure/0error eşitliğini doğruladı: gerçek X509Vnc/SPKI/password, frame/input, 960×720 resize ve authority retirement/no replay geçti. F61 CI bekliyor tablosuna taşındı: 58 seçili özellik ve toplam67 iş geniş son HEAD CI bekliyor. 37/127 ve3/63 tam kabul sayaçları değişmedi; fiziksel Huawei/DeX ayrı. [Kabul kanıtı](testing/f61-tigervnc-native-acceptance-2026-09-30.md).

### 1 Ekim F62 gerçek URI ayrıştırıcı düzeltmesi

Exactbc65ac5a/run36784045011 original named native testini bir kez/sıfır skip ile çalıştırdı; safe receipt `connectionFailureBeforeCertificate` gösterdi. Pinned FreeRDP URI converter ve cmdline tablosu, devre dışı kanal için kullanılan `key=-` seçeneklerinin geçersiz veya kanal açıcı olabildiğini doğruladı. Bu seçenekler kaldırıldı; `setConnectionInfo` sonucu kontrol edilip yalnız başarılı ayrıştırmadan sonra native `connect` çağrılır. TLS/NLA/SPKI ve pano politikası korunur. Root receipt-verified AAR ile production ve instrumentation Kotlin source setlerini derledi (279 task); owned-host kabulünün yerini almaz. Yeni native koşu değişen kaynakla yapılacak; F62 test bekliyor, 58 seçili/toplam67 CI bekliyor ve kabul sayaçları değişmedi. [Kanıt](testing/f62-freerdp-uri-parser-contract-2026-10-01.md).

### 1 Ekim F62 gerçek probe hata ayrımı

Exact78b28815/run36779907094 güvenli receipt beklenen class/methodun bir kez ve atlamasız çalıştığını, `inspect` certificate probe aşamasında başarısız olduğunu gösterdi. Ham XML tutulmadığı için aggregate shape bir çıkarım olarak kaldı. Public `engineUnavailable`, certificate return ve TLS/NLA/pinning korunur; dört sabit private probe sonucu ile strict tek-suite/count parser eklendi. Root 61 parser/kuyruk/progress testi ve receipt-verified AAR ile Kotlin derlemesi geçti. Gerçek packaged native kabul açık; F62 test bekliyor, CI bekliyor sayısı ve kabul sayaçları değişmedi. [Kanıt](testing/f62-probe-diagnostics-2026-10-01.md).

### 1 Ekim F61 resize bekleme sınırı

Exact6b2a7577/run36781108349 güvenli teşhisi yalnız owned test satır150 ile çözünürlük değişiminden sonraki kare bekleyişini belirledi. Önceki ACKden gelen eski boyutlu ara karenin gerçek Flutter consumer gibi ACK edilmesi dar TLS regression ile doğrulandı: root 5 gerçek TLS/0skip ve54 workflow/kuyruk/progress testini geçti. Actual hosted receipt henüz başarısız. F61 test bekliyor kalır; 57 seçili/toplam66 CI bekliyor ve kabul sayaçları değişmedi. [Kanıt](testing/f61-tigervnc-native-acceptance-2026-09-30.md).

### 1 Ekim F60 Core v2 kalıcı yetki dilimi

Core eşleme/katalog/dispatch için tek kullanımlık grant üretir; public host/app/session/command kimlikleri Core'a aittir. Current family sınırı, empty/reordered/missing katalog ve restart unknown/no replay tamamlandı. Root 28 odaklı ve backup/context/migration dahil 59 Server testini geçti. Client/native normal kanal, kalıcı pairing/catalog/revoke ve gerçek Sunshine kabulü geliştirmede; F60 CI bekliyor yapılmadı, sayaçlar değişmedi. [Core kanıtı](testing/f60-core-native-authority-v2-2026-10-01.md).

### 1 Ekim F61 owned-host zaman aşımı teşhisi

Exacta7458639/run36779316558 named TigerVNC testi awaitFrame/pumpUntil zaman aşımında düştü; önceki kare çeşitliliği assertionı verilmedi, fakat hangi adımda beklediği kanıtlanamadı. Runner yalnız source-bound allowlisted dosya/satır ve bounded count teşhisi çıkarır; mesaj/gizli yol/ham JUnit yok. 12 policy/runner testi geçti. Gerçek native kabul açık kaldı; CI bekliyor tablosuna taşınmadı, sayaçlar değişmedi. [Kanıt](testing/f61-tigervnc-native-acceptance-2026-09-30.md).

### 1 Ekim F62 native başlangıç teşhis kapısı

Exacte3ae7cb3 koşusunda receipted AAR ve gerçek APK buildleri geçti, fakat owned-host instrumentation başarısız. Güvenli çıktı yalnız report identity mismatch verdi; adlandırılmış testin çalıştığı kabul edilmedi. Başlangıç hatalarını sınıf/metod adı, mesaj veya gizli yol göstermeden owned source frame/count/boolean ile ayıran failure-only parser genişletildi; 30 odaklı tool testi geçti. Success receipt koşulu gevşetilmedi. F62 gerçek native kabulü açık, CI bekliyor sayısı ve kabul sayaçları değişmedi. [Kanıt](testing/f62-safe-native-failure-diagnostics-2026-09-30.md).

### 1 Ekim F61 gerçek RFB boyut bildirimi düzeltmesi

Actual TigerVNC exact2a585d3c koşusu ilk kare kontrolünde tekrar düştü. Root gerçek TLS peer ile metadata-only ExtendedDesktopSize mesajının yanlış boş kare yayınlanmasını RED olarak üretti; production parser artık metadata/gerçek pixels ayrımını, screen ID, resize refusal ve framebuffer korunmasını uygular. 49 native test (1 kasıtlı Linux skip), 4 gerçek TLS/0skip ve9 policy geçti. F61 yeni actual hosted receipt bekler; CI bekliyor yapılmadı, sayaçlar değişmedi. [Kanıt](testing/f61-tigervnc-native-acceptance-2026-09-30.md).

### 1 Ekim F60 gerçek gömülü Moonlight paket kanıtı

Exact Moonlight12.2 ve recursive kaynaklardan iki temiz AAR aynı SHA-256 üretti; root doğru AAR/receipt çiftini, kaynak lockunu ve izole gerçek APK içindeki DEX/iki ABI native eşleşmesini bağımsız doğruladı. 6 odaklı paket testi geçti. Bu paket/link kanıtı F60'ı CI bekliyor yapmaz: üretim eşleme/katalog, Core/native yetki ve oynatma/stop/revoke entegrasyonu geliştirmede. 57 seçili özellik/toplam66 CI bekliyor ve 37/127,3/63 kabul sayaçları değişmedi. [Paket kanıtı](testing/f60-moonlight-android-package-2026-09-30.md).

### 1 Ekim F28 kalıcı uyku timerı kabulü

Deadline pause artık normal Core scheduler→production Unix IPC→taze Music Assistant player/queue readback yolunda yürür. Root gerçek Flutter/Core iki yaşamını tekrar geçti; tek pause ve restartta no replay doğrulandı. 57 F28/music, ortak 46 Server ve 37 Flutter testi geçti; analiz temiz. Effect ile receipt arasında takeover public409 üretir; success veya kayıp ACK unknown sonucu korunur. F28 CI bekliyor tablosuna taşındı: 57 seçili özellik, toplam 66 iş. F60 geliştirmede, F61/F62 gerçek native kabul bekler; 37/127 ve 3/63 kabul sayaçları değişmedi. [Kabul kanıtı](testing/f28-sleep-timer-2026-09-30.md).

### 30 Eylül F22 kalıcı kanal devamı kabulü

Core artık occurrence başına kalıcı intent/command ve current family/user revision scope ile bearer süresinden bağımsız devam eder. Root gerçek Flutter→normal Core→owned Jellyfin iki yaşamını tekrar geçti; >900sn/refresh rotation, logout, exact v1 restart ve son receipt transaction iptali dahil 35 F22/ortak 46 Server testi geçti, scoped analyze temiz. IPC sonrası belirsiz etki tekrar gönderilmez. F22 CI bekliyor tablosuna taşındı: 56 seçili özellik, toplam 65 iş; kabul sayaçları değişmedi. Fiziksel receiver MANUAL açık. [Kabul kanıtı](testing/f22-personal-channels-normal-core-2026-09-30.md).

### 30 Eylül VNC ilk gerçek frame fixture düzeltmesi

Exact 2cf908b2/run36774361551 gerçek X509Vnc/SPKI/auth üzerinden ilk 800x600 framei aldı; fixtureın solid rootu ilk-frame çeşitlilik assertionını geçirmedi. Disposable xsetroot artık resmî X.Org -mod iki-renk patternını test öncesi boyar. Üretim TLS/backend veya native assertion değişmedi. Root 9 VNC policy, toplam 45 VNC/kuyruk/progress araç testini geçti. Yeni exact hosted sonuç açık; F61 CI bekliyor/done sayılmadı. [VNC kanıtı](testing/f61-tigervnc-native-acceptance-2026-09-30.md).

### 30 Eylül F47 geçmiş rezerv incelemesi kabulü

Gerçek Flutter Client→normal Core→owned evcc/HA iki yaşamı root tarafından tekrar geçti; 18 F47 Server ve F47/F28 ortak 37 Flutter testi geçti, scoped analyze temiz. Pinned evcc socTemp slot-start geçmişi current reserve ile karşılaştırılır; eksik forecast/multiple battery ve tarihsel reserve/capacity/manual tercih açık unknown kalır. Normal gözlem ilerlemesi sahte conflict üretmez, policy/service/authority drift reddedilir. F47 CI bekliyor tablosuna taşındı: 55 seçili özellik, toplam 64 iş; 37/127 ve 3/63 kabul sayacı değişmedi. Fiziksel inverter MANUAL açık. [Kabul kanıtı](testing/f47-reserve-backtest-2026-09-30.md).

### 30 Eylül RDP gerçek native hata kanıtı

Exact f5b382ce/run36772277001 arm64 paket/APK ve x86 paket/APK/NLA/emulator kapılarını geçti; named instrumentation çalıştı ve altı saniyede başarısız oldu. Saklanan log assertionı taşımadığı için neden varsayılmadı. Yeni runner yalnız exact source/package digest, static hata, allowlisted exception ve owned filename/line içeren bounded public failure receipt üretir; raw mesaj/credential/log/XML yayımlanmaz. Root paket runtime kaynaklarını da tanı kapsamına ekledi ve 28 araç testini geçti. F62 uygulanmış/native kabul bekliyor kalır; CI bekliyor veya done sayılmadı. [Tanı kanıtı](testing/f62-safe-native-failure-diagnostics-2026-09-30.md).

### 30 Eylül gerçek VNC protokol hatası ve SSH hosted kabulü

VNC exact f5b382ce/run36772273119 gerçek TigerVNC testine ulaştı ve TLS öncesi plaintext ready byteının eksikliğini buldu. Resmî TigerVNC1.13.1 sırasıyla düzeltildi; root 3 production native test/0 skip geçti. Yeni exact TigerVNC receipt açık, F61 CI bekliyor sayılmadı. SSH run36772281257 aynı exact source üzerinde güçlü yedi native test/sıfır skip receipt, normal Core, gerçek OpenSSH/SFTP/tunnel ve Android APK/contract adımlarını yeşil bitirdi; root public receipt SHA ve sayıları doğruladı. Geniş son HEAD CI ve fiziksel MANUAL açık; 37/127 ve 3/63 korunur. [VNC kanıtı](testing/f61-tigervnc-native-acceptance-2026-09-30.md), [SSH kanıtı](testing/f63-normal-core-openssh-2026-09-30.md).

### 30 Eylül F60 gerçek motor ile harici uygulama ayrımı

Moonlight kurulu bilgisi artık Larenor native motoru veya doğrulanmış host eşlemesi gibi gösterilmiyor. Harici uygulamaya geçiş Larenoru pause ettikten sonra geciken yanıt bir sonraki açılışı kilitlemez; stale tap native çağrı yapmaz, eski yanıt successor busy durumunu bozmaz. Root son doğrulamada 9 widget testi ve scoped analyze geçti; ilk yeni lifecycle fixtureının navigation bar altında kalan tapı düzeltildi ve başarısız koşu kanıt sayılmadı. Resmî Moonlight manifest/shortcut ve Sunshine API incelemesiyle pairing/native playback açığı korunur; F60 yeniden çalışılıyor kalır, sayaç artmaz. [Kanıt ve upstream sınırı](testing/f60-real-runtime-boundaries-2026-09-30.md).

### 30 Eylül native hosted kabul kapılarının dar düzeltmeleri

VNC generated Flutter önkoşullarını kurar ve exact bir class/method/sıfır skip JUnit receipt ister. RDP gerçek dependencyInsight ile app/test runner sürümünü yalnız receipted debug buildde hizalar; kabul artifacti yalnız sourceRevision, paket digest ve host sürümlerini içerir. SSH exact yedi test, loading/completion lifecycle ve observed host kimliklerini doğrular; root doğrudan workflow entrypointindeki PYTHONPATH bağımlılığını da düzeltti. Üç ajan diliminde root 43 focused Python testini ve py_compile/diff-checki geçti. Yeni exact hosted koşular gerekli; sayaçlar artırılmadı. [RDP bağımlılık kanıtı](testing/f62-android-test-resolution-2026-09-30.md), [SSH receipt](testing/f63-normal-core-openssh-2026-09-30.md), [VNC receipt](testing/f61-tigervnc-native-acceptance-2026-09-30.md).

### 30 Eylül tamamlanan yazılım ile gerçek açıkların ayrımı

K09 root tarafından gerçek normal Core/TLS MQTT, delayed-CONNACK/successor retirement ve 25 focused testle doğrulandı; tam Flutter analyze temiz. CI bekliyor tablosuna taşındı. Bağımsız kabul kapsamı denetimi F22, F28, F47 ve F60 için gerçek eksik yazılım davranışları buldu; mevcut alt dilim kanıtları korunarak dört iş yeniden çalışılıyor bölümüne alındı. Böylece 54 seçili özellik ve dokuz ek iş, toplam 63 iş geniş CI bekliyor. Kabul sayaçları değişmedi; FINAL.FUNCTION tek aktif FINAL olarak görünür. [K09 kanıtı](testing/k09-controlled-view-normal-core-2026-09-30.md), [açıkların kaynakları](testing/final-function-runtime-inventory-2026-09-30.md).

### 30 Eylül F61/F62 ortak hosted launcher ve host provenance

VNC ve packaged RDP runnerları aynı private pinned-Flutter Gradle launcherını kullanır; tracked olmayan gradlewe bağımlılık kaldırıldı. F62 owned Ubuntu shadow/WinPR paket sürümleri exact kurulur, dpkg readback ile doğrulanır ve Android FreeRDP3.31.1den ayrı receiptte kaydedilir. Root 20 Python policy/package/receipt testini geçti; fresh exact no-skip XML koşulu korunur. Bu runner düzeltmesi native interoperability veya cihaz kabulü sayılmadı. [F62 kanıtı](testing/f62-freerdp-native-acceptance-2026-09-30.md).

### 30 Eylül SSH exact native receipt kapısı

Hosted SSH gatei pinned Temurin17/Python3.12 ile çalışır; exact yedi native testin başlaması ve sıfır skip/error ile bitmesi bounded JSON receipt üzerinden zorunludur. Eksik fixture çevresi gerçek Flutter koşusunda yedi skip üretince parser bunu reddetti; yalnız doğrulanmış sayısal receipt artifacti yayımlanır. Root birleşik native readiness/policy kapısında 26 test geçti. Yeni exact hosted kabulü gerekli; eski yerel veya skipped exit0 başarı sayılmadı. [SSH kanıtı](testing/f63-normal-core-openssh-2026-09-30.md).

### 30 Eylül işlev envanteri kanıt uzlaşması

Feature matrix/runtime envanteri named exact Linux host/cgroup kanıtlarıyla güncellendi. Kapanmış composition eksikleri, geniş güncel HEAD CI ve fiziksel MANUAL kanıtları ayrı anlatılır. F47, Apple TV ve Camera bağımsız root kabulü kapandı; K09 retirement/handshake incelemesi ile F61/F62 yeni hosted native receipts açık. F63 yeni pinned-uv hosted koşusu başladı. FINAL.FUNCTION dışında yeni FINAL başlatılmadı. [İşlev matrisi](testing/final-function-feature-matrix-2026-09-30.md), [runtime envanteri](testing/final-function-runtime-inventory-2026-09-30.md).

### 30 Eylül VNC fresh-checkout Gradle launcher düzeltmesi

Exact645e5b73 / run36768307357 font ve sabit WM_CLASS fixtureını geçti, tracked olmayan android/gradlew fresh checkoutta bulunmadığı için native test başlamadı. Launcher pinned Flutter SDK wrapper JARını tracked proje properties ile private geçici dizinde çalıştırır; production RFB/TLS/auth koşulları korunur. Root 6 policy testini geçti; yerel 46 native testte beklenen tek non-Linux skip gerçek hosted kabulü sayılmadı. Yeni exact one-test/zero-skip sonucu gerekli. [VNC kanıtı](testing/f61-tigervnc-native-acceptance-2026-09-30.md).

### 30 Eylül SSH hosted runner önkoşulu

Exact8159c9a / run36767901119 gerçek SSH/SFTP/tunnel adımını geçti; normal Core adımı uv bulunmadığı için test başlamadan exit127 verdi. Workflow immutable resmi setup-uv ve exact uv sürümünü locked runner öncesi kurar; root 6 policy testini geçti. Yeni exact hosted sonuç gerekli, eski kırmızı koşu körlemesine tekrar edilmedi. [SSH kanıtı](testing/f63-normal-core-openssh-2026-09-30.md).

### 30 Eylül PRODUCT.CAMERA ve eski kuyruk nedenleri uzlaşması

Root 30 Flutter/0 skip, scoped analyze ve normal Android compile kanıtıyla Camera yazılımını CI bekliyor tablosuna taşıdı. Exact dialog ownership foreign-route callbackinden silme yapmaz; native listener retirement kamerayı kapatır. Fiziksel izin/busy/termal/batarya/ML doğruluğu MANUAL kaldı. Yeşil named Linux host/cgroup kanıtlarıyla kapanan F08/F15/F16/F18/F22/F25/F27/F28/F30/F40/F55 composition açıklamaları güncellendi; geniş güncel HEAD CI ile gerçek provider/cihaz kabulü ayrı ve açık, sayaçlar değişmedi. [Camera kanıtı](testing/product-camera-software-acceptance-2026-09-30.md), [host kanıtı](testing/unified-host-workers-2026-09-30.md).

### 30 Eylül F47 gerçek Client/Core/evcc kabulü

Gerçek birleşik kapı Flutter modelindeki eksik evcc servis türünü buldu ve düzeltildi. Root iki gerçek Core/Client yaşamında tek owned HA reserve gönderimini, causal readback, kalıcı kaynak bağını ve revizyon driftinde sıfır ek I/Oyu doğruladı. 14 Server/14 Flutter ve scoped analyze temiz. F47 yeniden çalışma bölümünden CI bekliyor tablosuna taşındı: 58 seçili özellik; fiziksel inverter/batarya/forecast MANUAL kaldı, kabul sayaçları değişmedi. [F47 kanıtı](testing/f47-normal-core-tcp-acceptance-2026-09-30.md).

### 30 Eylül PRODUCT.APPLETV yazılım kabulü

Root 67 Flutter ve gerçek authenticated HA TCP→production Client tek gönderim/nedensel readback kapısını doğruladı; scoped analyze temiz. Exact Apple TV kimliği ve capability taze doğrulanır, post-ACK authority kaybı unknown olur ve replay yoktur. MP4 adayının kodek/DRM uyumu açıkça doğrulanmamış gösterilir; fiziksel alıcı MANUAL.MEDIA içinde kalır. PRODUCT.APPLETV CI bekliyor tablosuna taşındı; kabul sayaçları değişmedi. [Apple TV kanıtı](testing/product-appletv-software-acceptance-2026-09-30.md).

### 30 Eylül F61/F62 yönetilen masaüstü profil kabulü

Core RDP/VNC artık source/endpoint/Core/home/account/family+profile digest v2 kasası, live authority, protocol action/panel ve exact DELETE sonrası local cleanup/retry kullanır. Yerel-only legacy kayıt korunur; SSH v2 digest byte eşitliği korunur. Root gerçek normal Core TCP gateini ve 34 focused Flutter/0skip kapısını doğruladı; analyze temiz. Gerçek TigerVNC/packaged FreeRDP hosted gate ayrı ve henüz yeşil değil; bu dilim native protocol veya fiziksel cihaz kabulü yerine sayılmadı, sayaçlar değişmedi. [Core masaüstü kanıtı](testing/f61-f62-core-managed-desktop-acceptance-2026-09-30.md).

### 30 Eylül FreeRDP gerçek host komut bağlamı düzeltmesi

Exact b76558c4 / run 36765836443 iki paket/APK ve NLA hostu geçti; KVM düzeltmesiyle emulator 29sn boot oldu. Action her script satırını ayrı shell ile çalıştırdığı için cd android sonraki gradlew komutuna taşınmadı, exit127 geldi; instrumentation başlamadı. Tek Python runner Android cwd/argvyi kendisi bağlar ve yeni exact XMLde bir named test/sıfır skip olmadan receipt vermez. 12 policy/package/receipt testi geçti; yeni exact host sonucu bekliyor. [RDP kanıtı](testing/f62-freerdp-native-acceptance-2026-09-30.md).

### 30 Eylül TigerVNC test penceresi kimliği düzeltmesi

Exact b76558c4 / run 36765832888 font hatasını kapattı; xterm başlığına göre pencere araması production test başlamadan timeout verdi. İzole pencere artık sabit WM_CLASS üzerinden bulunur ve owned bash startup dosyaları yüklenmez; visible-window/focus sınırı 10sn ve tüm gerçek native kabul koşulları korunur. 5 policy testi geçti; F61 gerçek hosted gatei geçmeden yazılım kabulü sayılmadı. [VNC kanıtı](testing/f61-tigervnc-native-acceptance-2026-09-30.md).

### 30 Eylül K11 kabulü ve F47 kanıt ayrımı

K11 explicit native retirement, sticky belirsiz ACK fence ve eski async yanıt epoch sınırlarını root 19 Flutter/6 Android sıfır skip ile doğruladı; analyze temiz. K11 CI bekliyor tablosuna taşındı, fiziksel cihaz kapıları MANUAL kaldı. F47nin declared gerçek Flutter→normal Core→TCP provider birleşik gatei henüz yok; ayrı Python/Flutter testlerini o kanıt yerine saymamak için F47 yeniden çalışılıyor. Böylece 57 seçili özellik ve altı ek iş (K10/K11/K12/K13, HEALTH/PROVIDERS) CI bekliyor; kabul sayaçları değişmedi. [K11 kanıtı](testing/k11-production-input-retirement-2026-09-30.md).

### 30 Eylül exact SSH MFA CI hatasının dar düzeltmesi

Exact b76558c4 / run 36765828318 owned Linux PAM akışında sıfır sorulu information roundunu reddeden gerçek Client hatasını buldu. RFC4256 izinli zero-response ve boş cevaplar bounded/host-trusted/visible confirmation yoluyla işlendi; 43 engine/controller/UI testi sıfır skip ile ve scoped analyze geçti. Parola, MFA ve jump ayrı named gerçek protokol kapılarına ayrıldı. F63 CI bekliyor kalır; yeni exact hosted sonuç henüz kabul edilmedi, sayaçlar değişmedi. [F63 kanıtı](testing/f63-normal-core-openssh-2026-09-30.md).

### 30 Eylül K13 terminal kurulum sonucu kabulü

PackageInstaller gönderimi artık yalnız pending gösterir. Exact nonce/session/package callbackinden sonra kurulu sürüm ve tek imza sertifikası PackageManagerdan doğrulanırsa confirmed olur. Commit attempt sonrası hata unknown kalır, restart ikinci gönderime izin vermez; geç exception terminal sonucu bozmaz. Root 68 Flutter ve Android20 focused kapısını geçti, scoped analyze temiz. K13 CI bekliyor tablosuna taşındı; fiziksel Device Owner/DPC/OEM kabulü MANUAL açık, sayaçlar değişmedi. [K13 kanıtı](testing/k13-managed-install-receipt-2026-09-30.md).

### 30 Eylül PRODUCT.PROVIDERS birleşik yazılım kabulü

Root gerçek Flutter Client→normal Core→private installation IPC→owned Music Assistant TCP iki yaşamını ve 26 Server/runtime testini geçti. Lost-create ACK exact readback bir upstream start tutar; secure dinamik form, authenticated loaded-instance readback, HTTPS Spotify dış akışı, abort ve logout kapanışı doğrulandı. Admin müzik merkezinden kurulum ekranı erişilebilir; fixture yokken TCP gate açıkça skip olur, başarı sayılmaz. PRODUCT.PROVIDERS CI bekliyor tablosuna taşındı; gerçek hesap/abonelik/çalma hakkı/HomePod kapıları MANUAL açık, kabul sayaçları değişmedi. [Sağlayıcı kanıtı](testing/product-music-provider-normal-core-acceptance-2026-09-30.md).

### 30 Eylül uzak ekran hosted fixture düzeltmeleri

F61 exact 939646c2 / run 36764619917 gerçek TigerVNCyi başlattı fakat xterm fixed Unicode fontu bulunamadığı için production test öncesi düştü; yalnız disposable fixturea xfonts-base eklendi. F62 exact 0513c841 / run 36762392915 iki AAR/APK ve NLA hostu geçti; KVM açık olmadığı için emulator bootunda instrumentation başlamadı. Established hosted char-device/access preflight ve hardware acceleration uygulanır; timeout büyütülmedi, üretim RDP gevşetilmedi. 5 VNC ve 11 FreeRDP workflow/package policy testi geçti. Yeni exact sonuçlar beklenir, iki özellik Core-managed adapter tamamlanmadan CI bekliyor yapılmadı. [VNC kanıtı](testing/f61-tigervnc-native-acceptance-2026-09-30.md), [RDP kanıtı](testing/f62-freerdp-native-acceptance-2026-09-30.md).

### 30 Eylül F63 yönetilen profil ve temizlik kabulü

Kaynak/Core/home/account/session-family kasası ayrıldı. Root gerçek normal Core/OpenSSH iki yaşamındaki SSH/SFTP/tunnel ve drift/logout kapanışını, ayrıca üçüncü fazdaki exact DELETE/readback→yerel temizlik hata→explicit retry yolunu geçti. Sunucu silme ve SSH komutları tekrar edilmedi. Bağlantı öncesi authority hatası EN/TR görünür; root son 24 Flutter, scoped analyze ve 5 workflow policy temiz. F63 CI bekliyor tablosuna taşındı: 58 seçili özellik; Linux password/key/MFA/jump ve geniş exact CI bekliyor, fiziksel cihaz kapıları açık. Kabul sayaçları değişmedi. [F63 kanıtı](testing/f63-normal-core-openssh-2026-09-30.md).

### 30 Eylül PRODUCT.HEALTH yazılım kabulü

Salt okunur gerçek SDK yolu, açık HA eşlemesi ve private-view/account/foreground sınırları bağımsız incelendi. Güncel 100 Flutter ve 21 Android wellbeing testi geçti; analyze temiz. PRODUCT.HEALTH CI bekliyor tablosuna taşındı; fiziksel cihaz/GMS/OEM ve gerçek Huawei/Apple sağlayıcı onayı MANUAL.HEALTH içinde açık, kabul sayaçları değişmedi. [Sağlık yazılım kanıtı](testing/product-health-software-acceptance-2026-09-30.md).

### 30 Eylül F54 zamanlanmış Android teslim kabulü

Google servislerinden bağımsız bildirim artık unique WorkManager immediate ve en az 15dk periyodik iş kullanır; yanlış remoteMessaging FGS ve özel boot receiver kaldırıldı. Root gerçek HTTPS Core→production Worker scheduler/store/renderer restart, dedupe ve Core DELETE revoke kabulünü geçti; 14 Kotlin, 34 Flutter, iki foreground normal Core lifetime ve analyze geçti. Async enqueue failure exact authorityyle görünür recovery olur; eski callback yeni leaseyi bozmaz. F54 CI bekliyor tablosuna taşındı: 57 seçili özellik; kabul sayaçları değişmedi. Android izin/reboot/Doze/OEM/Keystore/trust fiziksel kapıları açık. K13 submittedın terminal sonuç sayıldığı gerçek boşluk nedeniyle yeniden çalışılıyor. [F54 kanıtı](testing/f54-normal-core-native-delivery-2026-09-30.md).

### 30 Eylül F61 workflow ifade düzeltmesi

İlk TigerVNC dispatchi job-env içinde desteklenmeyen runner.temp bağlamı nedeniyle GitHub parse 422 ile reddedildi; hiçbir test çalışmadı. Gradle geçici dizini artık ilk stepte RUNNER_TEMPten GITHUB_ENVye yazılır; 5 workflow policy testi bu sınırı doğruladı. Gerçek hosted sonucundan önce başarı kaydedilmez.

### 30 Eylül F61 gerçek VNC host kapısı

Sentetik byte-server testi gerçek TigerVNC kabulü yerine kullanılmıyor. İzole Linux Xtigervnc X509Vnc karşısında normal production bridge SPKI, auth, frame, input, resize ve lifecycle/no-replay kapısı hazırlandı. Atlanmış veya Gradle cacheinden gelen test exit0 ile tamamlandı sayılmaz: exact XML bir test ve sıfır skip/failure gerektirir. 5 policy testi geçti; macOS gerçek host koşusu çalışmadı. Hosted exact sonucu ve Core-managed adaptör tamamlanmadan F61 implemented kalır; sayaçlar değişmedi. [F61 kanıtı](testing/f61-tigervnc-native-acceptance-2026-09-30.md).

### 30 Eylül F53 ve K10/K12 durum uzlaşması

F53 gerçek Core profilini kayıt, revision ACK, restart ve revoke boyunca uyguladı. K07/F53 ortak profil activation sınırı geç veya eski callbacklerin başka authority profilini silmesini engeller; root dört gerçek TCP/Flutter fazını ve 7 Server testini geçti. 50 focused Flutter ve scoped analyze temiz. K10 güncel 24 Flutter/12 Android ve K12 55 Flutter kapısı bağımsız doğrulandı. Üç iş CI bekliyor tablosuna taşındı: 56 seçili özellik ve iki kiosk işi; kabul sayaçları 37/127 ve 3/63 değişmedi. Fiziksel OEM/Device Owner/long-idle kapıları açık kalır. [F53 kanıtı](testing/f53-tablet-management-acceptance-2026-09-30.md), [K10 kanıtı](testing/k10-local-sensor-tablet.tdd.md), [K12 kanıtı](testing/k12-watchdog-local-usage-foundation.tdd.md).

### 30 Eylül exact Linux host CI kabulü

Exact `888dfd46f197808f91eaf0f85a4878e15ed27f8e` [run 36762186381](https://github.com/ersingundem/larenor/actions/runs/36762186381) yeşil tamamlandı. Gerçek production offline bundle, kurulu Core, dört cross-UID IPC/systemd kabulü ve disposable cleanup geçti. Bu named host kanıtıdır; daha sonraki branch HEADin geniş CI kabulü yerine geçmez. [Host kanıtı](testing/unified-host-workers-2026-09-30.md).

### 30 Eylül F54 kalıcı teslim iptali

Gerçek normal HTTPS Core→Android teslim deneyi eski lease revizyonu iptalden sonra 409 aldığı için şifreli teslim yetkisi ve bildirimin kaldığını buldu. İptal/expiry ve subscription permission reddi artık doğru credential için kalıcı 410 üretir; hâlâ aktif yenileme drift 409 olarak ayrı kalır, yanlış credential 401dir. Native revoke/restart deneyi geçti; 30 ilgili Server testi geçti. F54 Android iş planlaması ayrıca düzeltildiği için yeniden çalışılıyor kalır; bu dilim CI bekliyor veya cihaz kabulü sayılmadı.

### 30 Eylül Linux host kabulü ve cleanup düzeltmesi

Exact `b23e543ee30f064ad779d37cc45f7050f7125a16` run `36760951195` dört gerçek kurulu Core/IPC/systemd testini geçti. Koşu yalnız EXIT cleanupında root-owned bytecode izniyle düştü. Taze exact disposable proof tree noninteractive sudo ve one-file-system sınırıyla temizlenir; ilk test hata kodu korunur, cleanup hatası başarı sayılmaz. Bash syntax ve workflow policy geçti; yeni exact Linux sonucu ayrıca bekleniyor. Üretim izinleri gevşetilmedi. [Host kanıtı](testing/unified-host-workers-2026-09-30.md).

### 30 Eylül F52 gerçek ikinci ekran kabulü

Normal Core gerçek host ölçümlerini yetki öncesi/sonrası kontrolüyle kapalı public core.status snapshotına çevirir. Primary 5sn yeniler; isolated secondary 15sn sonra eski değerleri gizler. Root 4 Server ve iki gerçek TCP fazını bağımsız doğruladı; 24 Flutter, 5 Android DisplayManager/contract testi ve analyze geçti. F52 CI bekliyor tablosuna taşındı: 55 özellik geniş CI bekliyor, kabul sayaçları 37/127 ve 3/63 değişmedi. F53/K07 profil composition, F54 doğru Android iş planlaması ve F63 source/account kasa izolasyonu açık geliştirmede; yalnız local analiz geçen kod tamamlanmış sayılmadı. [F52 kanıtı](testing/f52-dual-display-2026-09-30.md).

### 30 Eylül gerçek Core katalog restart hatası

Exact `8b0de547` host run `36760057118` installerı geçti. İkinci gerçek Core startup integral clock timestampının SQLite REAL dönüşümü nedeniyle katalog HMACını reddetti. Default ve mutation zamanları hash öncesinde float olarak normalize edildi; eski hash veya bozuk kayıt yeniden imzalanmaz. İki gerçek restart/replay regresyonu ve F40 toplam 12 testi geçti. Yeni exact Linux gate henüz bekleniyor. [Host kanıtı](testing/unified-host-workers-2026-09-30.md).

### 30 Eylül F39 gerçek pano yeniden bağlantı kabulü

Kayıp iki HTTP başarı yanıtından sonra aynı immutable command secure cachete saklanır; yeni mutation kapalı kalır. Gerçek Core/Client restart exact receipt uzlaşmasıyla tek encrypted olayı korudu. İki oturum disjoint merge, same-item conflict/no retry, private delete cache purge ve route/logout sınırları geçti. Root 11 Server, 26 Flutter ve iki actual TCP fazını doğruladı; analyze temiz. F39 CI bekliyor tablosuna taşındı: 54 özellik geniş CI bekliyor; kabul sayaçları değişmedi. [F39 kanıtı](testing/f39-normal-core-acceptance-2026-09-30.md).

### 30 Eylül host CI makinesinin güvenli dizin önkoşulu

Exact `93ac3f29289b77fbd918dd6b2f035eee077b9e49` run `36758191763` üretim bundle buildini geçti; installer `release_opt_root_unsafe_dir` ile CI makinesinin root-owned fakat yazılabilir `/opt` dizinini doğru olarak reddetti. Yalnız disposable hosted test fixture exact nofollow descriptor/UID/GID/inode kontrolünden sonra modu 0755 yapar; production installer unsafe ancestorı değiştirmez ve reddetmeye devam eder. İzin/kimlik/symlink regresyonu geçti; hosted Linux kapısı yeni exact üzerinde doğrulanacak. [Host kanıtı](testing/unified-host-workers-2026-09-30.md).

### 30 Eylül F36 gerçek ev işi ve bildirim kabulü

Gerçek Client→normal Core iki yaşamında erteleme, Berlin DST, kayıp ACK uzlaşması, restart ve ayrılan üye skip/handoff doğrulandı. Yeni görev ataması aynı transaction içinde yalnız bir private F54 bildirimi üretir. Üyelik/revoke yarışları ve 32 kişi sınırı gerçek HTTP kapısında doğrulandı; 10 Server testi, focused Flutter, iki actual TCP fazı ve analyze geçti. F36 CI bekliyor tablosuna taşındı: 53 özellik geniş CI bekliyor; kabul sayaçları değişmedi. [F36 kanıtı](testing/f36-normal-core-acceptance-2026-09-30.md).

### 30 Eylül F37 gerçek düzeltme geçmişi kabulü

Masraf düzeltmesi eski encrypted kaydı ve ödemeyi koruyan linked yeni kayıt ekler; balance yalnız terminal masrafı hesaplar. Gerçek Client/normal Core restart, read postflight, filtered history, departed-member edit ve 53-bit gerçek Chrome sınırı doğrulandı. 19 Server, 15 Flutter, iki actual TCP fazı, 2 Chrome testi ve analyze geçti; bağımsız üç blocker kapandı. F37 CI bekliyor tablosuna taşındı: 52 özellik geniş CI bekliyor, kabul sayaçları değişmedi. [F37 kanıtı](testing/f37-normal-core-expense-corrections-2026-09-30.md).

### 30 Eylül F05 gerçek Home Workflow kabulü

Gerçek Client→normal Core→owned HA iki yaşamında explicit approval ve causal readback completed oldu. Exact create/approval replay ve ayrı cancel yalnız bir HA POST bırakır. 7 F05 Server, 2 focused Flutter/analyze ve iki actual runner geçti; root ilişkili 80 Server testini doğruladı. F05 CI bekliyor tablosuna taşındı: 51 özellik geniş CI bekliyor, kabul sayaçları değişmedi. F52/F53/F54 incelemedeki gerçek production bağlantı boşlukları nedeniyle geliştirmeye alındı. [F05 kanıtı](testing/f05-normal-core-home-workflow-2026-09-30.md).

### 30 Eylül host root kontrolünün somut koşulu

Son exact host hatası henüz kapanmadı. Installer filesystem/opt/prefix/releases/leaf ayrımını ve yalnız sabit owner=root/nonroot, mode=exact/safe/unsafe, type=dir/symlink/other sınıflarını güvenli aşama koduyla ayırır. Yol, UID numarası, ham mod, child stdout/stderr veya gizli içerik gösterilmez. 30 test geçti, 1 hosted-Linux kapısı yerelde skip; yeni exact koşu gerçek başarısız katmanı belirleyecek. Hiçbir eski exact körlemesine yeniden çalıştırılmadı.

### 30 Eylül host installer gerçek umask düzeltmesi

Exact `2c9ca9fb27c5bd4bd96e962c09dbd172c5005b69` host `36756593861` build sonrası `release_invalid:release_root` verdi. Python `parents=True` ara dizinlere leaf modunu uygulamadığından yeni dizin modları inherited umasktan bağımsız exact 0755/0700 yapıldı; mevcut yanlış mod/owner/symlink değiştirilmeden reddedilir. Umask 0002 regresyonu ve gerçek plugin paketleriyle 25 test geçti, 1 Linux kapısı yerelde skip. Ancak exact `37586155c1fb9f0fe137eafdd6414071a2bb4907` host `36757253756` aynı root kontrolünde düştü: umask değişikliği deterministik sertleştirmedir, bu CI hatasının kanıtlanmış nedeni değildir.

### 30 Eylül F21 gerçek izleme odası ve yeniden giriş kabulü

İki gerçek Flutter Client normal Core ve production medya read collector yoluyla room/invite/report/CAS akışını geçti. Fresh Core/Client restart lider rejoin sırasında gerçek session-family boşluğunu buldu; explicit rejoin artık oda lider family kimliğini atomik günceller ve eski family reddedilir. 29 Python, iki gerçek Flutter fazı ve analyze geçti; provider kapandıktan sonra sıfır yeni I/O. F21 CI bekliyor tablosuna taşındı: 50 özellik geniş CI bekliyor, kabul sayaçları değişmedi. [F21 kanıtı](testing/f21-normal-core-acceptance-2026-09-30.md).

### 30 Eylül F26 gerçek oynatma tavsiyesi kabulü

Production Flutter adapter/controller→normal Core→gerçek JellyfinClient owned provider negotiation yolunda exact bir authenticated PlaybackInfo POST yaptı; playback/quality yazısı yok. Reported codec/HDR/link verified sayılmaz. Client response sınırları Core ile eşlendi; 4 Server, 3 Flutter, gerçek normal gate, Android focused JVM ve analyze geçti. F26 CI bekliyor tablosuna taşındı: 49 özellik geniş CI bekliyor, kabul sayaçları değişmedi. [F26 kanıtı](testing/f26-normal-core-playback-quality-2026-09-30.md).

### 30 Eylül F04 gerçek kural/manuel çakışma kabulü

Gerçek Flutter→normal Core→owned HA iki yaşamında manual ownership kuralı provider öncesi bastırdı; exact bir POST restart/replay boyunca korunur. External HA gözlemi ayrı ve non-authoritative kalır. 5 focused Server ve iki gerçek faz geçti; root F04/F26 toplam 9 testi doğruladı. F04 CI bekliyor tablosuna taşındı: 48 özellik geniş CI bekliyor, kabul sayaçları değişmedi. [F04 kanıtı](testing/f04-normal-core-rule-arbitration-2026-09-30.md).

### 30 Eylül host installer kalan sabit tanı aşamaları

Exact `c5967d4ad390cf432358287918ca41e6597ba944` host `36754882780` production bundle buildini geçti ancak gerçek installer `release_invalid` verdi. Kalan root/receipt, 12 entrypoint layout ve iki gerçek plugin artifact kontrolü artık yalnız sabit allowlist aşamasını bildirir; çocuk çıktısı ve gizli değerler açılmaz. Gerçek callback/encoder ZIP üretimiyle 24 odaklı test geçti, 1 Linux kapısı yerelde skip. Davranış gevşetilmedi; yeni exact Linux sonucu beklenir, başarısız eski koşu tekrarlanmadı.

### 30 Eylül F13 gerçek egress grant/revoke kabulü

Gerçek Client→normal Core iki yaşamında grant/configure/restart/revoke, owned RFC1918 HA exact iki authenticated GET/api/config ve revoke sonrası sıfır ek upstream çağrı geçti. 69 Server ve 13 focused Flutter testi, analyze temiz; runner iki ajan tarafından doğrulandı. F13 CI bekliyor tablosuna taşındı: 47 özellik broad CI bekliyor, kabul sayaçları değişmedi. [F13 kanıtı](testing/f13-normal-core-tcp-acceptance-2026-09-30.md).

### 30 Eylül F19 gerçek iki Core kabulü

Gerçek Client iki bağımsız normal Core/home için ayrı profil/token/service kapsamını ve owned Jellyfin exact authenticated probe yolunu geçti. Registry restart sonrası Core A kapalıyken B çalışır; A failure profilleri silmez ve B recovery geçer. 47 Flutter, 177 Server ve iki gerçek faz doğrulandı; root birleşik runnerı ayrıca geçti. F19 CI bekliyor tablosuna taşındı: 46 özellik broad CI bekliyor; F37 eksik edit-history nedeniyle aktif geliştirmede. [F19 kanıtı](testing/f19-two-normal-core-acceptance-2026-09-30.md).

### 30 Eylül host installer güvenli hata aşaması

Exact `747b2717556e83d8a2e53d387cfd7ad134b75dce` host `36753201469` bundle üretimini geçti ancak gerçek production installer exit 1 verdi; test captured stderr'i gizlediği için hangi aşama olduğu kanıtlanamıyordu. Installer yalnız sabit allowlist aşama kodunu döndürür; child stdout/stderr/log/gizli içerik görünmez. Hosted test bu güvenli kodu görünür yapar. 7 odaklı test geçti, Linux kapısı yerelde skip; yeni tanı exact'i çalıştırılacak, eski koşu körlemesine tekrarlanmadı.

### 30 Eylül F59 gerçek yazıcı kayıt ve kontrol kabulü

Client authenticated OctoPrint/Moonraker servis kataloğundan yazıcı kaydeder; iş/ısı/stop yetkisi taze provider gözleminden türetilir. Filament miktarı gerçek API'de yoksa unknown/null kalır. Stable service registrationId kayıp ACK/restart çift kaydını önler; I/O sırasında admin iptali sıfır kayıt verir. 21 Server, 21 Flutter ve gerçek Client→normal Core→owned OctoPrint iki fazı geçti; pause POST sayısı restart/replay boyunca bir kaldı. F59 CI bekliyor tablosuna taşındı: 45 özellik geniş CI bekliyor, kabul sayaçları değişmedi. [F59 kanıtı](testing/f59-real-provider-2026-09-30.md).

### 30 Eylül F20 gerçek audit kontrol noktası kabulü

Gerçek Client→normal Core TCP pin/compare/rotate ve ayrı Core/Client restart geçti. Gerçek admin kayıtları zincire eklendi; SQLite actor tamper sonrası startup reddedildi, dump değişmedi ve bootstrap yeniden üretilmedi. Client checkpoint query reddi yalnız exact verification rotasında düzeltildi; iki transport regressionı ve 29 Server testi geçti. F20 CI bekliyor tablosuna taşındı: 44 özellik geniş CI bekliyor; accepted sayaç değişmedi. [F20 kanıtı](testing/f20-normal-core-audit-acceptance-2026-09-30.md).

### 30 Eylül F48 gerçek güç bütçesi Client/Core/evcc kabulü

Gerçek Client→normal Core→owned evcc üç fazda critical/default, route/logout sıfır yazı, tek 6A/4140W exact readback ve restart hold davranışını doğruladı. Son I/O boyunca Core/home/account/session/service yetki drift kontrolü eklendi; ortak Client exact 409 güvenli hata kodunu korur. Root 49 ilişkili Server testini, F48 üç fazını ve etkilenen F46 iki fazını geçti. F48 CI bekliyor tablosuna taşındı: 43 özellik geniş CI bekliyor; accepted sayaç değişmedi. [F48 kanıtı](testing/f48-evcc-manual-power-control-2026-09-30.md).

### 30 Eylül F32 gerçek kiler Client/Core kabulü

Gerçek pantry controller/API → normal TCP Core iki lot, FEFO tüketim, exact replay, undo, stale CAS ve restart sonrası kalıcı stok/tek undo kapısını geçti. Eski receipt ile güncel snapshotı yanlış reddeden Client düzeltildi; exact requestId/kind ve receipt revision sınırı korunur. 7 Server, 4 Client contract ve iki gerçek Client fazı root tarafından doğrulandı; analyze temiz. F32 CI bekliyor tablosuna taşındı: 42 özellik geniş CI bekliyor; fiziksel miktar/barkod/tablet ve kabul sayaçları ayrı kalır. [F32 kanıtı](testing/f32-normal-core-tcp-acceptance-2026-09-30.md).

### 30 Eylül F40 gerçek rezervasyon Client/Core kabulü

Gerçek Flutter→normal Core TCP create/restart kapısı catalog replay, reservation create/cancel, stale ikinci transport üzerinden receipt uzlaşması, kalıcı history/export ve authority retirementi geçti. Durable DB exact catalog created=1, reservation created=1/cancelled=1 olarak doğrulandı. Root 10 Server testi ve iki gerçek Client fazını bağımsız doğruladı. F40 CI bekliyor tablosuna taşındı: 41 özellik geniş CI bekliyor; accepted sayaç değişmedi. [F40 kanıtı](testing/f40-normal-core-acceptance-2026-09-30.md).

### 30 Eylül host wheelhouse kabulündeki gerçek marker düzeltmesi

Exact `e89dac174feaef6e9249390c758668ee3642adb0` host CI `36751825371` gerçek upstream wheel üretimini geçti; pinned `uv build` çıktı dizinine eklediği exact tek-byte `.gitignore` nedeniyle strict offline bundle wheelhouse reddedildi. Builder uv proje çıktısını ayrı dizine alır, yalnız exact marker ve tek regular Larenor wheel biçimini kabul eder, yalnız wheel'i bundle dizinine taşır. Strict bundle doğrulaması gevşetilmedi. Root F40 ve host paket odaklı toplam 16 testi doğruladı. Yeni exact host koşusu bu gerçek düzeltmeden sonra çalıştırılacak.

### 30 Eylül F46 gerçek EV Client/Core/evcc kabulü

Gerçek Flutter → normal Uvicorn Core → owned evcc TCP yolunda negatif tarife, 16→8 A plan/confirm, kayıp ACK, aynı command kimliğiyle tek POST ve GET exact readback geçti. Ayrı Core/Client restart sonrası aynı synthetic session family yeniden doğrulandı ve kalıcı verified makbuz okundu. 26 Server, 11 Flutter, iki gerçek Client fazı ve analyze geçti; fiziksel EV/utility feed kabulü iddia edilmedi. F46 CI bekliyor tablosuna taşındı; 40 özellik geniş CI bekliyor, F59 aktif geliştirme. Kabul sayaçları değişmedi. [Adlandırılmış kabul](testing/f46-normal-core-tcp-acceptance-2026-09-30.md).

### 30 Eylül F11 gerçek Wasmtime kabulü ve CI ayrımı

İmzalı/hash-sabitlenmiş katalog artifacti normal Core içinde gerçek Wasmtime ile çalışır: 50.000 fuel, 64 KiB linear memory, epoch backstop, kapalı WASI ve tek authorized-home scalar import uygulanır. Uygulanmayan CPU-ms/host RSS garantisi veya arbitrary upload iddiası yoktur. Upstream Rust 49.0.1/Python 49.0.0 yayın farkı resmî kaynaktan doğrulandı; etkilenen optional proposals kapatıldı ve gerçek call_ref compile reddi eklendi. 17 Server, 4 Flutter ve gerçek Flutter→TCP Core→Wasmtime kapısı geçti; root 17 testi ve normal runnerı bağımsız doğruladı. Wheel artifact/manifest/signature içerir. F11 CI bekliyor tablosuna taşındı; 39 özellik geniş CI bekliyor, yalnız F59 aktif geliştirme. Kabul sayaçları değişmedi. [F11 kanıtı](testing/f11-mini-plugin-truthful-boundary-2026-09-30.md).

### 30 Eylül F33 gerçek Client/Core kabulü ve kuyruk ayrımı

Kiler nested write transaction, JSON receipt restore ve Client canonical digest hataları gerçek TCP akışında bulunup düzeltildi. Gerçek Flutter → normal Core kapısı oturum/adım, atomik düşüm, tekrar gönderimde tek tüketim ve ayrı Core/Client restart sonrası kalıcı makbuzu doğruladı. 7 Server, 17 Flutter ve iki gerçek Client fazı geçti; root Server ve birleşik runnerı bağımsız doğruladı. F33 CI bekliyor tablosuna taşındı: 38 özellik geniş CI bekliyor; yalnız F11/F59 aktif geliştirme. F59 yazıcı kaydı UI eksikliği nedeniyle geliştirmeye alındı. 37/127 ve 3/63 kabul sayaçları değişmedi. [F33 kanıtı](testing/f33-normal-core-acceptance-2026-09-30.md).

### 30 Eylül exact F08 Linux kabulü ve Unmanic frontend kaynağı

Exact `09a912b4002f062757583df24f499731f507432c` için [F08 Linux CI 36750577813](https://github.com/ersingundem/larenor/actions/runs/36750577813) başarılıdır: gerçek ayrı UID IPC, OOM/resource_limit, TasksMax reddi, CPU throttling ve failed unit/cgroup temizliği geçti. Bu kapsam geniş Server/Android CI veya gerçek model kabulü değildir. Aynı exact host koşusu `36750580028`, upstream source arşivinin eksik git submodule dizininde durdu. Builder artık parent'ın exact frontend gitlink commitini ve arşiv/package-lock hashlerini doğrular, gerçek Node/npm engine sürümünü receipt'e kaydeder. Gerçek upstream wheel yerel izole source build ile üretildi; root 12 dar testi doğruladı. Düzeltilmiş exact host koşusu ayrıca gereklidir; eski kırmızı koşu tekrarlanmadı.

### 30 Eylül F51 birleşik Client/Core/HA kabulü

Gerçek Flutter Client normal Uvicorn Core üzerinden registry/CAS editörünü, canlı HA switch projectionını, tek authorized mutation ve idempotent replayi çalıştırdı. Registry değişimi eski save isteğini reddetti, katalog onarımı geçti; ayrı ikinci Core ve Client süreci restart sonrası layout/rotation/vector verisini okudu. 9 Server ve 13 Flutter testi, iki gerçek Client fazı geçti; CI bekleme etiketi ve sayaçlar değişmedi. [Adlandırılmış kabul](testing/f51-normal-core-tcp-acceptance-2026-09-30.md).

### 30 Eylül başarısız AI unit cleanup düzeltmesi

Exact `6a79199d` F08 Linux koşusu gerçek ayrı UID IPC, OOM, TasksMax ve CPU throttling senaryolarını geçti; tek kalan hata failed transient unit/cgroup temizliğiydi. Production release artık yalnız exact dispatch unit üzerinde stop ardından reset-failed yapar. Hata varsa ancak başarılı bounded show ile exact LoadState=not-found kanıtı kabul edilir; bus/show hatasında descriptor/receipt silinmez. 24 odaklı test geçti, 4 hosted-Linux skip açık. Root ayrıca 14 dar testi doğruladı (1 Linux skip). Yeni exact Linux sonucu gerekir; eski kırmızı koşu tekrarlanmadı.

### 30 Eylül Unmanic paket sürümü ve gerçek Core health düzeltmesi

Exact `6a79199d` host CI, doğrulanmış Unmanic arşivinde Git metadatası olmadığından UNKNOWN.VERSION ile wheel üretiminde durdu. Builder yalnız exact regular UNKNOWN placeholder'ı upstream 0.4.1 etiketi→sabit commit ilişkisinden gelen sürümle değiştirir ve bunu receipt'e kaydeder; gerçek upstream setup.py --version çıktısı 0.4.1 doğrulandı. Kurulu Core TCP yardımcısının health yolu normal `/api/v1/health` olarak düzeltildi; testi artık gerçek create_app çalıştırır. 22 odaklı test geçti, 4 hosted-Linux kapısı yerelde atlandı. Yeni exact host sonucu ayrıca beklenir.

### 30 Eylül F12 gerçek SDK kabulü ve CI bekleyen kuyruk

20 odaklı Server/boundary, 51 admin/context ve official Python MCP SDK 2.2.0 gerçek Uvicorn TCP kapısı geçti; root 20 testi ve SDK kabulünü bağımsız tekrar doğruladı. Gerçek SDK ile bulunan yeni sürüm offer/_meta hatası düzeltildi. F12 CI bekliyor grubuna geçti; 37 özellik geniş CI bekliyor, yalnız F11 aktif. 37/127 ve 3/63 kabul sayaçları değişmedi. Custom bearer/client-header yolu desteklenir; OAuth credential discovery iddiası yoktur. [Adlandırılmış kanıt](testing/f12-mcp-streamable-http-2026-09-30.md), [63 özellik üretim yolu matrisi](testing/final-function-feature-matrix-2026-09-30.md).

### 30 Eylül Keenetic gerçek RCI revizyon ve WAN kanıtı

Gerçek RCI version/readback sözleşmesinde olmayan sentetik revision alanları kaldırıldı. Firmware kimliği gerçek release/model/hardware/manufacturer verisinden aynı BLAKE2 fingerprint ile doğrulanır; fingerprint sıralı sayaç gibi karşılaştırılmaz. Misafir ağı/istemci işlemlerinde son başarı ayrıca güncel normal provider okumasını ve istenen değeri gerektirir. WAN yeniden bağlamada online→online veya ilgisiz aggregate değişimi nedensel kanıt olmadığı için sonuç dürüstçe unknown kalır ve tekrar gönderilmez. 190 Keenetic testi geçti; gerçek bağlantı session/event kanıtı ve fiziksel router kabulü açık. [Kanıt ve sınır](testing/keenetic-host-worker-2026-09-30.md).

### 30 Eylül kurulu host paketinden gerçek Core kabulü

Hosted Linux kapısı artık exact commitin Server wheel'ini ve hash/revision sabitlenmiş gerçek Unmanic wheel'ini üretim offline bundle builder/installer yoluyla kurar. Sahte executable ve source sanal ortamına symlink kaldırıldı. Mesh/Keenetic kabulü kurulu release içinden normal Core'u gerçek Uvicorn TCP üzerinden başlatır; dev TestClient/httpx bağımlılığı gerekmez ve module yolu kurulu release altında doğrulanır. Bundle receipt exact kaynak SHA, platform ve wheel/manifest digestlerini kaydeder. 21 odaklı test ve 16 workflow/shard politika testi geçti; actual Linux kurulum, ayrı UID ve servis kapıları CI sonucunu bekliyor. Fiziksel Docker/Btrfs/media önkoşulları olmayan ortamda activation kabulü iddia edilmez.

### 30 Eylül F08 gerçek Linux başlangıç düzeltmesi

Exact Linux `36746628951` koşusu sağlayıcı başlamadan `218/EXIT_CAPABILITIES` ile duruyordu. systemd v255 kaynak incelemesi, user manager'ın `ProtectKernelModules` için capability bounding set düşürmesini yapamadığını doğruladı. Bu seçenek yalnız system manager'da korunur; user manager dedicated unprivileged UID, NoNewPrivileges, namespace ve cgroup limitlerini korur. 21 odaklı runtime/paket/IPC testi geçti; 4 gerçek Linux kapısı macOS'ta açıkça atlandı. Yeni exact Linux sonucu henüz bekleniyor; yerel testler Linux kabulü sayılmıyor. [systemd kaynak kanıtı](https://github.com/systemd/systemd/blob/v255/src/core/unit.c).

### 30 Eylül exact Security CI ve F49 kuyruk kanıtı

`fd6a6a4246c8c7824c63763e17ec5773d2e0a62d` için [Security CI 36747936989](https://github.com/ersingundem/larenor/actions/runs/36747936989) platform-policy, secret-scan ve dependency-scan kapılarının tümünü geçti. Bu yalnız Security kanıtıdır; Server/Linux/Android ve tüm FINAL kabulü yerine geçmez. F49'un adlandırılmış gerçek Flutter→normal Core→TCP HA/OpenSprinkler kabulü doğrulandı ve CI bekliyor grubuna taşındı. Artık 36 özellik geniş CI bekliyor; F11/F12 geliştirmede. 37/127 ve 3/63 sayaçları değişmedi.

### 30 Eylül geniş platform kapısında IPC ayrımı

Eski kurulum/yükseltme kabulü, yeni worker socket mount’unu kalıcı özel veri gibi sınıflandırdığı için 24 hata veriyordu. Yalnız exact Core `/run/larenor-workers`→sabit host IPC kaynağı volatile olarak ayrıldı; Core/servis özel verisinin exact digest/sentinel koruması aynen sürer. Yanlış kaynak veya başka hedef/servis bu istisnaya girmez. 45 dar kurulum/yükseltme testi ve 454 platform/policy kontrolü geçti (4 desteklenmeyen yerel kapı skip). Exact HEAD Security CI ayrıca bekleniyor; önceki kırmızı koşu körlemesine tekrarlanmadı.

### 30 Eylül F11 gerçek sınır sözleşmesi

Sabit metadata eklentisinin uygulanmayan 50 ms CPU/1 MiB bellek garantileri Server ve Client v2 sözleşmesinden çıkarıldı. Gerçek 1 KiB çıktı, ağ/dosya erişimi olmayan sabit işlem, yetki/ev sınırı ve durdurma korunur; eski yanlış v1 sözleşmesi Client tarafından reddedilir. 4 odaklı Server ve 4 Flutter loopback testi, analyze geçti. F11 geliştirmede kalır: tam CPU/bellek izolasyonlu eklenti kabulü henüz yoktur. [Kanıt ve açık kapsam](testing/f11-mini-plugin-truthful-boundary-2026-09-30.md).

### 30 Eylül F45 bildirim kabulü ve dürüst kuyruk sınıflandırması

F45 gerçek Frigate→F54 özel bildirim yolu restart/kayıp ACK dedupe ve commit öncesi kaynak/oturum/kamera yetki kontrolüyle tamamlandı. Yeni 7 test, birleşik 69 test ve 28 Core context testi geçti; root ayrıca 35 handoff/context testini doğruladı. F45 CI bekliyor tablosuna taşındı; 35 özellik geniş CI bekliyor. F11 CPU/bellek iddiası gerçek uygulamayla uyuşmadığından geliştirmeye alındı. F12 protokol bağlantısı da geliştirmede. 37/127 ve 3/63 kabul sayaçları değişmedi. [F45 kanıtı](testing/f45-f54-notification-handoff-2026-09-30.md).

### 30 Eylül F08 Linux fixture yolu ve F12 protokol incelemesi

F08 sağlayıcı fixture dosyaları production private state gibi /var/lib altına taşındı; PrivateTmp izolasyonu gevşetilmedi. Stres fixture kernel sayaçlarını cgroup hâlâ canlıyken okur. Actual `98f5dcdc` host koşusundaki umask kaynaklı NUT socket dizini modu explicit 0770 olarak düzeltildi. Önceki /tmp receipt yolu sağlayıcı ve worker için farklı namespace oluşturuyordu. F12 grant/araç kabulü gerçek, fakat standart initialized notification ve HTTP transport sınırları ayrıca düzeltiliyor; F12 geliştirmeye alındı ve CI bekliyor sayısı 34 kaldı.

### 30 Eylül Linux kabulünde gerçek NUT başlangıç hatası

Exact `5beb0813` host koşusu `36745640680`, production NUT worker'ın context-manager yöntemlerinin yanlış kapsamda kaldığını gösterdi. Yöntemler gerçek runtime sınıfına taşındı; socket başlangıcı başarısız olsa da singleton lock bırakıldığı doğrulandı. 14 focused test geçti, 1 Linux testi yerelde atlandı; 8 workflow testi geçti. İzole root pytest cache yazımı kapatıldı. Yeni Linux sonucu bekleniyor; kör rerun yapılmadı.

### 30 Eylül F29 gerçek Parti DJ kabulü

Normal Core ve production MusicPlaybackRuntime, gerçek TCP Music Assistant fixture üzerinde kuyruk ekleme/readback, iki kullanıcı oyu/skip, restart ve kayıp ACK uzlaşmasını doğruladı. 35 focused test geçti; F29 da CI bekliyor tablosuna geçti. 35 özellik geniş CI bekliyor; kabul sayaçları değişmedi. [Kanıt](testing/f29-party-dj-production-2026-09-30.md).

### 30 Eylül F08 gerçek cgroup stres kabulü

Linux kabul kapısına gerçek worker üzerinden OOM, TasksMax fork reddi ve CPU throttling senaryoları eklendi. MemoryPeak'in geçici olarak limiti aşamayacağı varsayımı kaldırıldı; kernel sayaçları ve exact uygulanan limitler birlikte doğrulanır. 17 yerel test geçti, 3 Linux testi macOS'ta açıkça atlandı; 26 workflow/policy testi ve actionlint geçti. Actual Linux sonucu bekleniyor. [Kanıt](testing/f08-standalone-ai-runtime-2026-09-30.md).

### 30 Eylül Keenetic gerçek host worker ve nedensel doğrulama

Unified Core, özel veri izinlerini koruyarak UID10008 Keenetic worker'a ayrı IPC mount üzerinden bağlanır. Docker PID namespace varsayımı kaldırıldı; gerçek socket peer ve worker receipt doğrulanır. Gerçek TCP RCI kabulünde ortaya çıkan iki pre-state/readback hatası düzeltildi. 141 Keenetic ve 9 paket testi geçti; dedicated UID Linux, geniş CI ve fiziksel router kabulü açık. [Kanıt](testing/keenetic-host-worker-2026-09-30.md). Sayaç değişmedi.

### 30 Eylül kuyrukta CI bekleyen uygulamalar

Uygulama ve odaklı kanıtı tamamlanan 34 özellik `awaiting_ci` olarak ayrıldı. Test/review eksikleri olan uygulamalar alt tablonun test bekleyen bölümünde, F45 gerçek bildirim bağlantısı aktif geliştirmede kalır. CI bekliyor etiketi tam kabul veya fiziksel cihaz kabulü sayılmaz; 37/127 ve 3/63 sayaçları değişmedi.

### 30 Eylül F18 gerçek NUT ve Proxmox host bağlantısı

NUT producer, durable sıralı outbox ve kayıp ACK uzlaştırması normal Core ingest’e bağlandı. Proxmox ayrı UID10005 worker ile bounded health/socket identity üzerinden çalışır; Core veri dizini açılmaz. İzole snapshotta 75 focused ve 8 paket testi geçti; 2 hosted Linux kapısı macOS üzerinde atlandı. [Kanıt](testing/f18-power-recovery-production-2026-09-30.md). Fiziksel UPS/Proxmox ve exact HEAD geniş CI açık; sayaç değişmedi.

### 30 Eylül FINAL.FUNCTION Linux worker kabulü

Farklı kullanıcılarla gerçek IPC/systemd kabulü, exact committed kaynak ve kurulu paketleri ayrı `/tmp` ortamında kullanacak şekilde bağlandı. F08 ve host kapıları yalnız dar teşhis için ayrı seçilebilir; tam Server aggregate iki kapıyı da zorunlu tutar. 34 workflow/policy testi ve actionlint geçti; actual Linux sonucu henüz bekleniyor. F45 gerçek bildirim teslim bağlantısı şu anda geliştirmede; F41 uygulaması geniş CI tablosunda.

### 30 Eylül özel Core verisi ve ayrı worker IPC

Worker socketleri özel Core veri dizininden çıkarılıp yalnız IPC içeren ayrı mount’a taşındı. Core veri/anahtar izinleri 0700 kalır; dedicated kullanıcılar ortak IPC grubuyla iletişim kurar. 7 izole paket regresyonu geçti; gerçek farklı UID/systemd başlangıcı Ubuntu kabulünde açık. [Kurulum sınırları](testing/unified-host-workers-2026-09-30.md).

### 30 Eylül F15/F16 gerçek component host worker

Normal Core bileşen snapshot/update/restore işlemleri gerçek Unix IPC worker’a bağlandı. Installation journal seti temiz kurulum ve kesintili başlangıç için kalıcı receipt ile doğrulanır; kayıp geçmiş sessizce yeniden oluşturulmaz. 54 odaklı ve 19 paket/bundle testi geçti; Linux distinct UID kapısı yerelde atlandı. [Kanıt](testing/f15-f16-component-host-worker-2026-09-30.md). Docker/Btrfs hedef ve geniş CI açık; sayaç değişmedi.

### 30 Eylül F55 gerçek host Zigbee worker

Unified Core dedicated UID10004 worker’a gerçek broker/IPC üzerinden bağlanır; private MQTT config, kernel peer UID ve socket ancestor ownership doğrulanır. 26 provider/Core ve 11 paket/runtime testi geçti. Linux distinct UID ve geniş CI açık; fiziksel OTA uygulanmadı, sayaç değişmedi. [Kanıt](testing/f55-mesh-host-worker-2026-09-30.md).

### 30 Eylül host worker kurulum yolları

Sanal ortam geçici dizinden taşınmıyor; actual console başlangıç komutları ve bağımlılıklar receipt yayınından önce doğrulanıyor. Gerçek offline pip/venv yol regresyonu geçti. Tam production bundle ve Linux servis kabulü açık; sayaç değişmedi. [Kanıt](testing/unified-host-workers-2026-09-30.md).

### 30 Eylül F09 doğru hafıza kaynağı ve gerçek Client kabulü

Public API yalnız manual kaynak yazabilir; hesap kimliği ve restore provenance mutasyon öncesinde doğrulanır. Client snapshot parserı düzeltildi, geçmiş non-manual kaynaklar önceki beyan olarak görünür ve doğrulanmış AI receipt sayılmaz. 10 Server ve 2 gerçek Flutter→normal Core TCP kabulü geçti; analyze temiz. [Kanıt](testing/f09-ai-memory-provenance-2026-09-30.md). Geniş CI açık; sayaç değişmedi.

### 30 Eylül F01 gerçek yerel ses ve açık taslak hedefi

Android yerel EN/TR STT ve offline TTS gerçek platform providerına bağlandı. İzin/kayıt ayrı gesture, açık HA hedefi, düzenleme/iptal, boş veri ve Retry tamamlandı. 10 native, 11 Flutter, 3 Server ve 1 gerçek Flutter→normal Core→TCP HA kabulü geçti; analyze temiz. [Kanıt ve model/cihaz sınırı](testing/f01-local-speech-drafts-2026-09-30.md). Actual AOSP emulator speech/TTS provider taşımıyor; MANUAL modeli ve geniş CI açık, sayaç değişmedi.

### 30 Eylül geniş CI ilk hata düzeltmeleri

Security exact `9bc92d369` koşusunda iki eski politika beklentisi başarısızdı: multiline zorunlu aggregate ve dört sabit loopback medya portu. Dar düzeltmelerle 449 platform-policy testi geçti, 4 skip; security policy temiz. Android exact `d8f17838f` biçim kapısındaki üç dosya formatter ile düzeltildi. Actual Linux AI user-manager hazırlık hatası ayrıca inceleniyor; koşu yeniden başlatılmadı ve yeşil kabul iddia edilmedi.

### 30 Eylül F44/F47 gerçek ev revizyonu

Frigate gözlemleri ve evcc enerji girdileri actual Home Resource Registry revizyonunu taşıyor; schemaVersion veya sabit 1 authority olarak kullanılmıyor. Kamera 21, enerji/evcc 25 Server regresyonu geçti. [Kamera kanıtı](testing/f44-real-frigate-classification-2026-09-30.md), [enerji kanıtı](testing/f47-solar-battery-priorities-core.tdd.md). Geniş CI ve fiziksel provider kabulü açık; sayaç değişmedi.

### 30 Eylül F08 normal Core → gerçek host AI yürütücüsü

Docker Core, özel peer UID doğrulamalı Unix IPC üzerinden ayrı UID10003 worker ve systemd user manager’a bağlandı. Kaynak sınırı, gerçek process receipt ve kalıcı iptal/release korunuyor; config ve host paket kurulum akışı tamamlandı. 42 Server ve 6 paket testi geçti; 3 actual Linux kapısı macOS üzerinde skip, required Ubuntu CI bekliyor. [Kanıt](testing/f08-standalone-ai-runtime-2026-09-30.md). Model ve fiziksel hedef kabulü açık; sayaç değişmedi.

### 30 Eylül F38 doğru albüm kaynağı

Immich çok-albümlü arama sonuçları ilk albüme yanlış atanmıyor; her albüm ayrı aranıp sonuçlar kaynaklarını koruyarak birleştiriliyor. 40 Server ve 1 gerçek Flutter→normal Core→TCP Immich kabulü geçti, analyze temiz. [Kanıt](testing/f38-normal-source-2026-09-30.md). Geniş exact HEAD CI bekliyor; sayaç değişmedi.

### 30 Eylül gerçek host worker paketi

Müzik ve medya kurulum worker’ları host Docker kimliğini doğrular; archive/Unmanic gerçek medya UID’siyle çalışır. Core yalnız özel IPC grubuna katılır, exact peer UID korunur; offline wheel paketi hash doğrulanır ve özel politikalar olmadan etkinleşmez. 56 paket/workflow kapısı ve odaklı IPC/runtime geçti; actual Linux UID/systemd kapıları CI bekliyor. [Kanıt ve hedef kurulum sınırları](testing/unified-host-workers-2026-09-30.md). Capacity fixture eski silinen dal yerine actual checkout HEAD’i kullanır; sayaç değişmedi.

### 30 Eylül F35 gerçek belge OCR

Normal Core şifreli belgeyi gerçek Poppler/Tesseract ile sınırlı yerel süreçte okur; tarih adayı confidence ve source digest taşır, kullanıcı onayı olmadan hatırlatma oluşturmaz. 24 Server, 14 Flutter, 1 gerçek Flutter→normal Core→actual OCR kabulü ve 21 container policy testi geçti; analyze temiz. [Kanıt ve image build kapısı](testing/f35-home-document-ocr-2026-09-30.md). Geniş exact HEAD CI açık; sayaç değişmedi.

### 30 Eylül F28 ev üyesi müzik erişimi

Ready ev üyeleri normal Core müzik akışını açıp doğrulayabilir, katalog arayıp oynatıcıyı kontrol edebilir; sağlayıcı kurulumu admin yetkisinde kalır. 35 Server, 24 Flutter, 1 gerçek Flutter→normal Core→production HTTP runtime→TCP Music Assistant kabulü geçti; analyze temiz. [Kanıt ve açık host paket kapısı](testing/f28-member-music-access-2026-09-30.md). Host IPC paketi ve geniş exact HEAD CI bekliyor; sayaç değişmedi.

### 30 Eylül F07/F10 gerçek Home Assistant history kanıtı

Alışkanlık ve tanılama Client’ları görünür, bağlı ev kaynağını seçer; Core gerçek entity registry ve history okur. Eksik baseline uydurulmaz, eski/client kaynaklı kanıt sentetik etiketlidir; tanılama otomatik repair effect uygulamaz. 13 Server ve 1 gerçek Flutter→normal Core→HA TCP/WS kabulü, odaklı Flutter/analyze geçti. [Kanıt](testing/f07-f10-ha-history-evidence-2026-09-30.md). Exact HEAD CI/geniş kabul açık; sayaç değişmedi.

### 30 Eylül F08 gerçek yerel iş yürütücüsü

Core kalıcı dispatch/iptal/terminal journal ile gerçek standalone providerı OS cgroup sınırında çalıştırır; kayıp start cevabı tekrar effect göndermez, tamamlandı sonucu gerçek receipt/output hash'i ve readback gerektirir. 31 Server ve 4 Flutter geçti, analyze temiz. Actual Linux cgroup kabulü yerelde atlandı; required CI job buna zorunlu bağlandı. [Kanıt ve provider kapsamı](testing/f08-standalone-ai-runtime-2026-09-30.md). Exact HEAD CI/geniş kabul açık; sayaçlar değişmedi.

### 30 Eylül F24 tek oynatıcı dil tercihi deposu

Eski Jellyfin endpointi aktif oynatıcıyla aynı şifreli kaydı kullanır; mevcut eski tercihlerin güvenli startup aktarımı ve revizyon çatışması korunur. 10 Server, 8 Flutter ve 1 gerçek Flutter→normal Core TCP kabulü geçti; analyze temiz. [Kanıt](testing/f24-shared-player-preferences-2026-09-30.md). Exact HEAD CI/geniş kabul bekliyor; sayaçlar değişmedi.

### 30 Eylül F23 gerçek Jellyfin kayıt yönetimi

Normal Core gerçek Jellyfin guide/timer kurulumu, kayıt/iptal/restart ve Client admin kaynak seçimine bağlandı. Tüm upstream kayıtların byte hesabı, bilinmeyen boyut ve kalıcı otomatik quota-stop düzeltildi. 8 Server ve 1 gerçek Flutter→Core TCP→Jellyfin kabulü geçti, analyze temiz. [Kanıt ve disk politikası sınırları](testing/f23-jellyfin-live-tv-provider-2026-09-30.md). Tam exact HEAD CI ve fiziksel tuner/sert filesystem kotası manuel kapıda; sayaçlar değişmedi.

### 30 Eylül F17 ayrı TLS yedek hedefi ve uzak kurtarma

Ayrı append-only hedef, kalıcı sealed kota/saklama ve recovery kimliğiyle gerçek şifreli indirme uygulandı. Normal Core günlük export→TLS hedef→download→boş Core restore/start, erişim iptali ve quota/tamper dahil 7 Server testi; 38 Flutter testi, 12 boundary regresyonu ve analyze geçti. [Kanıt ve kurulum sınırları](testing/f17-append-only-target-2026-09-30.md). Tam exact HEAD CI ve ayrı hedef fiziksel kurulumu açık; kabul sayaçları değişmedi.

### 30 Eylül F45 gerçek ses olayları

Gerçek Frigate ses review ve exact metadata GET akışı normal Core üzerinden bağlandı. Offline rıza iptali kaydedilir; mevcut kamera ve oda izinleri her görünümde yeniden doğrulanır. Ham ses veya klip saklanmaz, sessiz veri gelmemesi sessizlik kanıtı sayılmaz. 12 Server, 14 Flutter ve gerçek Client→Core→TCP kabulü geçti; analyze temiz. [Kanıt ve sınırlar](testing/f45-frigate-sound-events-2026-09-30.md). Fiziksel kamera ve exact HEAD CI açık; sayaçlar değişmedi.

### 30 Eylül F41 özel olay yetkisi

Gerçek arama sonucundan üretilen AES-GCM olay mührü restart/önbellek süresi sonrasında güncel kamera iznini korur; yeni dönüşüm gerçek klip varlığına bağlıdır, mevcut şifreli paylaşımın alıcı/süre/iptal yetkisi ayrıdır. 8 normal Core/TCP mühür testi ve 40 odaklı regresyon geçti. [Kanıt ve sınırlar](testing/f41-private-event-binding-2026-09-30.md). F42/F44/F45/F50/F57 gerçek provider düzeltmeleri sürüyor; kabul sayaçları 37/126 ve 3/63 olarak değişmedi.

### 30 Eylül FINAL.FUNCTION — tek final maddesinin kabul koşusu

Tek çalışma dalındaki fonksiyonellik geçişi Client/Flutter, Android platform
ve Server/Core olarak kapatılıyor. Uygulama test tabanı `06f5551a` üzerinde
Flutter tam paketinde 7.637 test geçti, 4 platform testi atlandı; statik analiz
sıfır sorunla geçti. `52b30612` üzerinde tüm platform politika paketi 442 geçti,
4 atlandı. Server/Core tam paketi ve exact-head CI bekleniyor.
Backup v3 geri kazanma kimliği, Home Assistant komut makbuzu, oynatma kalite
gözlemi, tablet uzaktan sözleşmesi, müzik sağlayıcı gizliliği ve ağ fixture
kapanış yarışı bulunan gerçek uyumsuzluklar olarak düzeltildi. İlerleme kapısı
workflow tabanı `52b30612` dahil 323 commit'i doğruladı. Ayrıntılı komut ve kapsam
[FINAL.FUNCTION kabul kaydında](testing/final-function-acceptance-2026-09-30.md)
tutuluyor.

`FINAL.FUNCTION` incelemesi **F30 ve ek production composition boşlukları nedeniyle yeniden çalışılıyor**. 30 Eylül canlı denetiminde F18 kesilmiş hedef adımının tekrar gönderilebildiği, F59 sağlayıcısız onayın etki üretmeden kaydedildiği ve F46/F48/F55 concrete runtime sağlayıcılarının eksik olduğu doğrulandı. İlgili kuyruk maddeleri uygulama işi olarak yeniden açıldı; önceki tarihli uygulama kayıtları kapanış kanıtı değildir.
Unmanic/Jellyfin resmî sözleşmesi, tipli hedefler, gerçek read/action worker,
yeniden başlatma/iptal/uzlaştırma ve Client→Core→worker kabulü tamamlandıktan
sonra tam paketler ile exact-head CI yeniden çalışacak. Bu sırada `FINAL.UI`,
`FINAL.AUDIT`, `FINAL.CI`, `FINAL.GALLERY` ve `FINAL.README` bağımlılık
bekleyecek; aynı anda ikinci final maddesi alınmayacak. Sayaçlar **37/126
(%29,4)** ve **3/63 (%4,8)** olarak değişmedi.

### 30 Eylül gerçek sağlayıcı düzeltmeleri — kabul sayaçları değişmedi

`61fa2835` doğrulanmış Proxmox VM/LXC hedefini admin ekranından seçip recovery politikasına kaydeder; 14 Flutter testi geçti. `b1fedff0` evcc bağlantısını her istekte güncel doğrulanmış servisten kurar ve negatif tarifeleri explicit, kalıcı enerji pencerelerinde korur; admin metadata GET revizyon değişiminden sonra CAS yenilemeyi sağlar. `d8daf8f7` gerçek Zigbee envanterinin bilinmeyen alanlarını uydurmadan gösterir ve kesilmiş OTA gönderimini belirsiz makbuzla durdurur. `97ddbf19` korunmuş orijinali yalnız başarılı dönüşüm kanıtı, güncel yetki ve kalıcı silme niyetiyle temizler; 126 odaklı Server regresyonu geçti. Bu commitler tek çalışma dalına gönderildi; kapsamlı yazılım kabulü ve exact HEAD CI açık olduğundan **37/126** ile **3/63** sayaçları artmadı.

### 27 Eylül F08 tarihsel uygulama kaydı — 30 Eylül runtime boşluğu nedeniyle yeniden açıldı

F08 Core üzerinde HMAC ile bütünlüğü korunan kalıcı kaynak politikası ve iş
kuyruğu kurdu. Bellek, CPU ve eşzamanlı iş sınırları; öncelik, idempotent istek
anahtarı, iptal/tamamlama revizyonu ve 512 etkin iş sınırıyla uygulanıyor.
Zaman aşımıyla kendiliğinden kapanan medya lease'i etkin olduğunda ayrı düşük
CPU tavanı kullanılıyor. Kota, yüksek öncelikli iş, medya baskısı ve gerçek
donanım yetersizliği birbirinden ayrı açık durumlar olarak raporlanıyor.

Core her görünümde gerçek süreç belleğini ve çekirdek sayısına normalize sistem
yükünü ölçüyor, HMAC'li ve 256 kayıtla sınırlı geçmişte saklıyor. Flutter
yönetici ekranı güncel donanım/ölçüm/tahsis durumunu, üç güvenli politika
profilini ve iptal edilebilir işleri hesap/Core/ev/rota/foreground sınırında
gösteriyor. Jellyfin oynatıcı 90 saniyelik kısa lease'i 45 saniyede yeniliyor;
duraklatma, arka plan, hesap değişimi veya kapanışta bırakıyor ve çöken Client
kalıcı baskılama bırakamıyor. `2cec8aaa`, `66b9f61a` ve `353961c3` dilimleri
şema/idempotence/medya baskılama/iptal smoke'u, Python compile, l10n üretimi ve
odaklı Flutter analyze kapılarından geçti. Kullanıcının kararı gereği özellik
testleri final toplu doğrulamaya bırakıldı. F08 **uygulama tamamlandı · test
bekliyor**; sayaçlar **37/125 (%29,6)** ve **3/63 (%4,8)** olarak değişmedi.
Gerçek AI yüküyle izole Core E2E, yetki/iptal/bozuk-geç cevap ve limit testleri,
bağımsız inceleme, düşük donanım ölçümü ve exact-head CI açık kalıyor.

### 27 Eylül F19 birden fazla ev, bağımsız Core — uygulama tamamlandı, test bekliyor

F19 tek Core/ev Server güvenlik sınırını koruyarak Client üzerinde en fazla 16
bağımsız Core profilini Secure Storage içinde yönetiyor. Legacy tek oturum kaydı
kayıpsız taşınıyor; ev değişimi eski API ve callback nesillerini ilk ağ isteğinden
önce emekli ediyor ve Core/ev/hesap kimliği değişince bütün ProviderScope runtime'ı
yeniden kuruluyor. Medya önbellek anahtarları kimliklerin SHA-256 kapsamına alındı;
arama yalnız güncel runtime'ın pasif cache görünümünü okuyor.

Core yedeği v3 kaynak Core/ev kimliğini ve replacement niyetini taşıyor; geri
yüklenen Core yeni adresten girişte ikinci kopya yaratmadan mevcut profili atomik
yeniden bağlıyor. Evler arası hazırlık kaynak ve hedef Core'u ayrı oturumlarla
canlı doğruluyor, hiçbir token veya önbelleği paylaşmıyor. Etkin profil kendi F17
silmeye kapalı kurtarma hedefi ekranına bağlanabiliyor. `f49d783c`, `7a1c3485`,
`68894e05`, `ef26d9bb`, `61b648ad`, `bbc49a36` ve `01bee407` dilimleri Python
compile, l10n üretimi ve odaklı Flutter analyze kapılarından geçti. Özellik
testleri, bağımsız son inceleme, iki izole gerçek Core E2E ve exact-head CI final
doğrulama evresinde açık olduğundan F19 **uygulama tamamlandı · test bekliyor**;
sayaçlar **37/125 (%29,6)** ve **3/63 (%4,8)** olarak değişmedi.

### 27 Eylül F53 evdeki tabletleri tek yerden yönetme — uygulama tamamlandı, test bekliyor

F53'ün güncel uygulaması eski `codex/f53-tablet-fleet-client` dalındaki teslimi
aşıyor. Core; Core/ev/oturum ailesi yetkisine bağlı kayıt, iptal, heartbeat,
profil revizyonu, süreli ve idempotent komut, sonuç makbuzu, denetim günlüğü ve
imzalı kademeli dağıtım önizlemesi sunuyor. Yanlış ev, değiştirilmiş kayıt veya
iptal edilmiş tablet fail-closed reddediliyor; standart uygulama ile Device
Owner komut yetenekleri hem sözleşmede hem yönetim ekranında ayrı gösteriliyor.

Client; yönetici ekranı, belirsiz komut sonucu uzlaştırması, sürümlü profil
yayınını okuyan cihaz senkronizasyonu, güvenli credential deposu, foreground ve
hesap/rota nesil sınırı ile native Android kiosk durum kaynağını ürün runtime'ına
bağlıyor. `8f4a743d`, `19095110`, `022ba38c` ve `b4272e38` teslimleri güncel
branch'in atasıdır. Güncel Server kaynakları Python compile, ilgili Server,
kiosk runtime, ayarlar ve bağlantı ekranları odaklı Flutter analyze kapılarından
geçti. Kullanıcının kararı gereği özellik testleri final toplu doğrulamaya
bırakıldı. F53 **uygulama tamamlandı · test bekliyor**; sayaçlar **37/125
(%29,6)** ve **3/63 (%4,8)** olarak değişmedi. Gerçek Client→izole Core E2E,
yetki/iptal/bozuk-geç cevap ve limit testleri, bağımsız inceleme, exact-head CI
ile Huawei/OEM/DPC fiziksel kabulü açık kalıyor.

### 27 Eylül F18 elektrik kesintisinde düzenli kapanış — uygulama tamamlandı, test bekliyor

F18 tek çalışma dalında tamamlandı. Core; sürümlü UPS politikası, revision'a
bağlı şifreli kaynak anahtarı ve sıra/zaman doğrulamalı olay sözleşmesiyle
sahte, eski ve yinelenen olayları reddediyor. Kritik olay yeni ağır işleri
tutuyor, etkin işleri sınırlı sürede boşaltıyor, SQLite WAL checkpoint alıyor,
hedefleri bağımlılık sırasında kapatıyor ve enerji kararlı kaldıktan sonra
yalnız gerçekten kapanmış hedefleri ters sırada açıyor. Adımlar ve sonuçlar
kalıcı; yeniden başlatmada çalışan adım güvenli yeniden kuyruğa alınıyor,
başarısız işlem kullanıcı retry'ı için korunuyor.

Flutter yönetici ekranı UPS kaynağı/eşik/hedef sırası politikasını, kapı ve
etkin işlem durumunu, retry akışını ve kalıcı makbuz geçmişini güncel hesap,
PIN, rota ve foreground sınırında yönetiyor. `ec0cfc3b`, `7b971db4` ve
`cabd9324` dilimleri sözleşme smoke'u, failed-run restart smoke'u, Python
compile, l10n üretimi ve odaklı Flutter analyze kapılarından geçti. Kullanıcının
kararı gereği özellik testleri final toplu doğrulamaya bırakıldı. F18
**uygulama tamamlandı · test bekliyor**; sayaçlar **37/125 (%29,6)** ve
**3/63 (%4,8)** olarak değişmedi. Exact-head CI, bağımsız son inceleme ve
gerçek UPS/host kapanış kabulü açık kalıyor.

### 27 Eylül F20 değişikliği fark edilen işlem günlüğü — uygulama tamamlandı, test bekliyor

F20'nin Core çapındaki HMAC zincirli audit journal'ı ve yönetici doğrulama
endpointi `2fe7f701` ile, Core/ev kapsamındaki güvenli Client checkpoint
pinleme, karşılaştırma ve döndürme akışı `86dcbf89` ile tek çalışma dalına
alındı. Testler, dış kontrol noktası kabulü, bağımsız inceleme ve exact-head CI
final doğrulama evresinde açık olduğu için F20 **uygulama tamamlandı · test
bekliyor**; kanıtla tamamlandı sayılmadı.

### 27 Eylül F54 Google servislerinden bağımsız bildirim — uygulama tamamlandı, test bekliyor

F54'ün yerel bildirim kutusu, kullanıcı onaylı Android arka plan teslim kirası,
Keystore korumalı kimlik bilgisi, görünür foreground service, boot/recovery,
kayıp/tekrar dedupe ve fail-closed yenileme/iptal zinciri Server, Flutter ve
native Android katmanlarında mevcut. Güncel sertleştirme `c08020dd` ile tek
çalışma dalına alındı. Özellik testleri, bağımsız inceleme, exact-head CI ve
gerçek Huawei/OEM pil davranışı final doğrulama evresinde açık olduğundan F54
**uygulama tamamlandı · test bekliyor**; kanıtla tamamlandı sayılmadı.

### 27 Eylül F17 silinemez kurtarma hedefi — uygulama tamamlandı, test bekliyor

F17 tek çalışma dalında tamamlandı. `63907e92` sürümlü hedef politikasını,
ayrı append/recovery kimliklerini, şifreli sır saklamayı ve silme ucu olmayan
yönetim API'sini kurdu. `c5067b24` günlük zamanlayıcıyı, çökme sonrası aynı
nesne ve payload ile sürdürülen append-only aktarımı, uzak makbuz kontrolünü
ve korumalı geri dönüş noktası geçmişini ekledi. `1555bb99` Flutter yönetim
ekranında hedef, saklama, kota, ayrı kimlik bilgileri, sonraki koşum ve korumalı
geri dönüş noktalarını bağladı.

Şema geçişi ve idempotence smoke'u, gerçek Core yedeği kullanan zamanlayıcı/
makbuz smoke'u, l10n üretimi ve odaklı Flutter analyze temiz geçti. Kullanıcının
kararı gereği yanlış politika, erişim iptali ve bozuk/geç cevap özellik testleri
final toplu doğrulama evresine bırakıldı. F17 **uygulama tamamlandı · test
bekliyor**; sayaçlar **37/125 (%29,6)** ve **3/63 (%4,8)** olarak değişmedi.
Bağımsız inceleme, exact-head CI ve gerçek NAS/uzak append-only hedef kabulü
açık kalıyor.

### 27 Eylül F16 otomatik kurtarma tatbikatı — uygulama tamamlandı, test bekliyor

F16 tek çalışma dalında tamamlandı. Core; sürümlü istek/iş/makbuz sözleşmesi,
tek aktif tatbikat, 64 kayıtla sınırlı kalıcı geçmiş, idempotent elle başlatma,
iptal ve deadline sınırları sunuyor. Dispatcher her adımda güncel yönetici
yetkisini doğruluyor ve kesilen çalışan işi güvenli biçimde yeniden ele alıyor.
Fresh şifreli yedek yalnız özel geçici dizinde açılıyor; boş Core veritabanı,
vault anahtarı, yapılandırma, aile panosu ve bileşen arşivleri üretim worker
soketleri kapalıyken bütünlük ve sağlık denetiminden geçiyor. Sonuç makbuzu
üretim etkilerini reddeden politikayı, doğrulanan kaynakları ve sınırlı hata
kodunu saklıyor. Kalıcı 30 günlük plan güncel hesap rolü/revision'ını tekrar
doğrulayarak aynı tek-aktif iş kuyruğunu kullanıyor.

Flutter yönetici ekranı aylık planı açıp kapatıyor, sonraki zamanı ve son 20
makbuzu gösteriyor, elle çalıştırma ve etkin işi iptal etme akışlarını güncel
oturum/rota/foreground sınırında yürütüyor. `ddcdce43`, `8e4c9101`, `2a1e111e`,
`a84c4d13` ve `e4e8d84b` dilimleri Python import/izole full-restore smoke,
l10n üretimi, odaklı Flutter analyze ve diff kapılarından geçti. Kullanıcının
kararı gereği özellik testleri son toplu doğrulama evresine bırakıldı. F16
**uygulama tamamlandı · test bekliyor**; sayaçlar **37/125 (%29,6)** ve
**3/63 (%4,8)** olarak değişmedi. Yetki/iptal/bozuk-geç cevap ve limit test
paketi, bağımsız inceleme, gerçek Client→izole Core/servis E2E ve exact-head CI
açık kalıyor.

### 27 Eylül F61 bağımsız VNC — framebuffer hattı uygulandı, backend açık

F61'in `723138aa`, `cb2023a5` ve `3213b4e6` dilimleri native EventChannel
üzerinden gerçek bounded RGBA piksel sahipliğini, tek outstanding frame/ACK
akışını, Flutter decode-paint yüzeyini ve ürün panelindeki lifecycle kapanışını
bağladı. İnceleme, paketli native motorun hâlâ `UnavailableVncNativeBackend`
kullandığını doğruladı. Gerçek TLS/RFB taşıması, ilk sertifika keşfi, VNC auth,
IME/touchpad/zoom/resize ve izole host kabulü tamamlanmadan F61 açık kalır.

### 27 Eylül F62 bağımsız RDP — uygulama tamamlandı, test bekliyor

F62'nin doğrudan cihaz profili, receipted FreeRDP Android motoru ve tablet
oturumu güncel tek çalışma dalında ürün ekranına bağlı. Hedef, port, kullanıcı,
Windows domain ve RD Gateway ayarları kişisel profil sınırında tutuluyor; parola
ve gateway parolası şifreli kasada saklanabiliyor. TLS/NLA zorunluluğu ile
hedefe özgü SPKI sertifika pini sessiz düşürmeye izin vermiyor. BGRA ekran
kareleri sahipli ve sınırlı aktarılıyor; touchpad, fiziksel klavye, Türkçe/IME,
dinamik çözünürlük, DPI ve DeX dış ekran akışları aynı oturum yetkisine bağlı.

Native motor yalnız exact FreeRDP kaynak/ABI makbuzu APK içinde doğrulandığında
açılıyor; desteklenmeyen RD Gateway, ses veya dosya kanalı bağlanmış gibi
gösterilmiyor. Pano izni kapalı, cihazdan uzağa veya çift yönlü seçilebiliyor;
`5128e30a` ekran kanıtını gerçek seçili politikayla eşleştirdi. Temel Client
teslimi `14e429a7`, Android motoru `8b73f24b` ve bounded Türkçe/IME girdisi
`0ad4b431` güncel branch HEAD'inin atalarıdır. Güncel RDP ve profil kaynakları
odaklı Flutter analyze kapısından hatasız geçti. Kullanıcının kararı gereği
özellik testleri yeniden çalıştırılmadı. F62 **uygulama tamamlandı · test
bekliyor**; sayaçlar **37/125 (%29,6)** ve **3/63 (%4,8)** olarak değişmedi.
İzole gerçek Windows/NLA/gateway E2E, kanal yetenek matrisi, bağımsız inceleme,
fiziksel Huawei/DeX kabulü ve exact-head CI açık kalıyor.

### 27 Eylül F63 SSH, SFTP ve güvenli tüneller — uygulama tamamlandı, test bekliyor

F63'ün doğrudan cihaz profili, SSH terminali, SFTP ve tünel uygulaması güncel
tek çalışma dalında mevcut ve ürün ekranına bağlı. Parola veya şifreli özel
anahtar, klavye etkileşimli MFA, hedef ve jump-host anahtar parmak izi
sabitlemesi, PTY yeniden boyutlandırma, UTF-8/Türkçe çıktı, çoklu terminal
sekmeleri ve komutun bağlantı koptuğunda otomatik tekrarlanmaması uygulanıyor.
SFTP; sınırlı dizin listeleme, açık kullanıcı seçimiyle indirme/yükleme,
dosya boyutu ve yol normalizasyonunu koruyor. Tüneller yalnız loopback'te
dinliyor, bağlantı sayısını sınırlıyor ve profil/hesap/rota/foreground/pencere
yetkisi kaybolunca bütün soketleri kapatıyor.

Temel teslim `717f6dbc`, terminal çıktı bütünlüğü `1abab368`, SFTP yol ve buffer
sertleştirmesi `1351869d` commitlerinde bulunuyor; üçü de güncel branch HEAD'inin
atası olarak doğrulandı. Güncel SSH/SFTP/tünel ve ortak oturum kaynakları odaklı
Flutter analyze kapısından hatasız geçti. Kullanıcının kararı gereği özellik
testleri yeniden çalıştırılmadı ve final toplu doğrulamaya bırakıldı. F63
**uygulama tamamlandı · test bekliyor**; sayaçlar **37/125 (%29,6)** ve
**3/63 (%4,8)** olarak değişmedi. İzole gerçek SSH hostu handshake/MFA/jump/
SFTP/kopuş E2E, bağımsız inceleme, fiziksel Huawei/DeX kabulü ve exact-head CI
açık kalıyor.

### 27 Eylül F56 eski cihaz akıllı kumandası — uygulama tamamlandı, test bekliyor

F56 tek çalışma dalında tamamlandı. Core; hesap, oturum ailesi, Core/ev,
sağlayıcı, köprü, cihaz, profil ve kod seti revision'larına bağlı, şifreli ve
sürümlü bir kumanda kataloğu tutuyor. Allowlist dışındaki komutlar reddediliyor;
komut önce exact önizleme ve kullanıcı onayı alıyor, teslim sonucu kalıcı
makbuzla yeniden okunuyor ve belirsiz sonuç otomatik tekrarlanmıyor. Yeni
öğrenme sözleşmesi ham IR sinyalini Larenor'a taşımadan sağlayıcı sınırında
tuşu kaydediyor; profil ve kod seti revision'larının monoton ilerlemesini ve
kalıcı makbuz eşleşmesini şart koşuyor.

Tablet Client, kumanda tuşlarını erişilebilir Apple tarzı bölümlerde gösteriyor,
öğrenilecek tuşu seçtiriyor ve orijinal kumandayı köprüye yöneltme adımını açık
onayla başlatıyor. Başarı yalnız öğrenme makbuzunun POST ve GET readback
sonuçları birebir eşleşip yenilenen katalogda görünmesinden sonra gösteriliyor;
sinyal teslimi hiçbir yerde cihazın fiziksel durumu olarak sunulmuyor.
`3ccf6ad4` ve `1a8d1707` dilimleri Python py_compile/import/rota smoke, odaklı
Flutter analyze ve diff kapılarından geçti. Kullanıcının kararı gereği özellik
testleri son toplu doğrulama evresine bırakıldı. F56 **uygulama tamamlandı ·
test bekliyor**; sayaçlar **37/125 (%29,6)** ve **3/63 (%4,8)** olarak
değişmedi. Gerçek Client→Core→IR köprüsü E2E, geç/bozuk/iptal ve limit paketi,
bağımsız inceleme, fiziksel donanım kabulü ve exact-head CI açık kalıyor.

### 27 Eylül F32 dolap stoğu ve son kullanma — uygulama tamamlandı, test bekliyor

F32 tek çalışma dalında tamamlandı. Core; gram, kilogram, mililitre, litre ve
adet birimlerini kesin tamsayı ölçülere normalize eden sürümlü bir stok defteri
tutuyor. Lot ekleme, en erken son kullanma tarihinden deterministik tüketme ve
tüketimi geri alma revision CAS ile korunuyor. İstek kimlikleri aynı içerikte
idempotent makbuz döndürüyor, farklı içerikte yeniden kullanım ve yinelenen
barkod/lot reddediliyor. Bounded defter durumu Core/ev/revision AAD'sine bağlı
AES-GCM kayıt olarak saklanıyor ve açılışta tablo, şifreli içerik, receipt ve
movement bağları yeniden doğrulanıyor.

Tablet Client, doğrulanmış Core oturumunda ürün/birim/miktar/son kullanma
tarihi girişi, barkoddan kararlı lot kimliği, yaklaşan tarihe göre lot görünümü,
stoktan tüketme ve son tüketimi geri alma akışlarını sunuyor. Rota; hesap,
Core/ev, pencere odağı, foreground ve etkileşim epoch'u değişince geç cevapları
iptal edip tuttuğu stok kanıtını bırakıyor. `08c3b98b` ve `5360be61` dilimleri
Python py_compile/import/schema smoke, odaklı Flutter analyze ve diff
kapılarından geçti. Kullanıcının kararı gereği özellik testleri son toplu
doğrulama evresine bırakıldı. F32 **uygulama tamamlandı · test bekliyor**;
sayaçlar **37/125 (%29,6)** ve **3/63 (%4,8)** olarak değişmedi. Gerçek
Client→Core E2E, eşzamanlı tüketim/yinelenen okuma/undo paketi, bozuk ve geç
cevaplar, bağımsız inceleme ve exact-head CI açık kalıyor.

### 27 Eylül F28 sesli kitap ve podcast merkezi — uygulama tamamlandı, test bekliyor

F28 tek çalışma dalında tamamlandı. Core, Music Assistant'ın güncel provider
otoritesindeki yarım kalmış sesli kitap ve podcast bölümleri için hesap,
oturum ailesi, kurulum, Core ve manager revision'larına bağlı kalıcı dinleme
oturumu tutuyor. Her yazma revision CAS ile korunuyor; başka oturum ailesindeki
dinleme yalnız açık devralmayla değiştirilebiliyor. Konum, oynatma durumu, en
fazla 64 yer imi ve 60 saniye–24 saat arası uyku sayacı HMAC etiketli depoda
tutuluyor ve her güncellemede güncel katalog öğesiyle yeniden doğrulanıyor.

Client, dinlemeye devam kartından açılan merkezde doğrulanmış alıcı seçimi,
kuyruğa güvenli provider URI'si gönderme, kaldığı konuma seek, oynatma,
duraklatma, bölüm seçimi, yer imi ve uyku sayacı akışlarını sunuyor. Android
LocalAudio MediaSession sesli kitap/podcast metadata türünü, başlangıç konumunu,
arka planda devamı ve gerçek zamanlı uyku sayacını destekliyor. `db93800e`,
`4aa40499`, `a5c67d28` ve `bf3fa24a` dilimleri Python py_compile/import,
Android debug Kotlin compile, Flutter l10n üretimi, odaklı Flutter analyze ve
diff kapılarından geçti. Kullanıcının kararı gereği özellik testleri son toplu
doğrulama evresine bırakıldı. F28 **uygulama tamamlandı · test bekliyor**;
sayaçlar **37/125 (%29,6)** ve **3/63 (%4,8)** olarak değişmedi. Gerçek
Client→Core→Music Assistant E2E, sağlayıcı/format matrisi, arka plan uyku sayacı
ve fiziksel alıcı davranışı, bağımsız inceleme ve exact-head CI açık kalıyor.

### 27 Eylül F27 seyahat için çevrimdışı medya — uygulama tamamlandı, test bekliyor

F27 tek çalışma dalında tamamlandı. Core yalnız güncel Jellyfin katalog
otoritesinin indirmeye uygun, boyutu ve SHA-256 kimliği bilinen dosyaları için
hesap, oturum ailesi, Core/ev, kurulum, snapshot, servis ve medya revision'ına
bağlı süreli grant üretiyor. En fazla yedi günlük ve aktör başına 32 grant,
20 GiB Client kotası, monoton ilerleme, final digest, iptal ve her parçada
yeniden yetki denetimi uygulanıyor. Jellyfin API anahtarı izole worker'dan
çıkmıyor; dosya exact `Range`/`Content-Range` sözleşmesiyle 32 KiB parçalar
halinde taşınıyor.

Client her parçayı grant'e özel Secure Storage anahtarıyla AES-256-GCM
şifreleyip atomik kaydediyor, mevcut parçaları yeniden hashleyerek indirmeye
kaldığı yerden devam ediyor ve tamamlanan kopyayı diske açık metin yazmadan
yalnız rastgele yollu loopback HTTP üzerinden menzilli olarak oynatıyor. Hesap
veya oturum ailesi değişimi, grant süresinin dolması, iptal ve rota yaşam
döngüsü oynatma kiralamasını kapatıyor; DRM veya harici abonelik sağlayıcısını
indirme yolu açılmadı. `daff7d40`, `1e5f2196` ve `debdbc5a` dilimleri Python
py_compile, Flutter l10n üretimi, odaklı Flutter analyze ve diff kapılarından
geçti. Kullanıcının kararı gereği özellik testleri son toplu doğrulama evresine
bırakıldı. F27 **uygulama tamamlandı · test bekliyor**; sayaçlar **37/125
(%29,6)** ve **3/63 (%4,8)** olarak değişmedi. Gerçek
Client→Core→Jellyfin E2E, kesinti/devam/kota/süre sonu yolculukları, bağımsız
inceleme ve exact-head CI açık kalıyor.

### 27 Eylül F21 birlikte senkron izleme — uygulama tamamlandı, test bekliyor

F21 tek çalışma dalında tamamlandı. Core artık güncel Jellyfin katalog
otoritesine bağlı, en fazla 16 katılımcılı ve altı saatle sınırlı özel izleme
odaları tutuyor. Davet kodu yalnız hashlenmiş olarak saklanıyor; oda,
katılımcı, hedef ve komut revision'ları her yazmada yeniden doğrulanıyor.
Katılımcı yeniden katılımı oturum ailesini yeniliyor, liderlik yalnız bağlı bir
katılımcıya devredilebiliyor ve lider ayrılırsa güncel bağlı katılımcılardan
biri deterministik biçimde lider oluyor. Etkin katılımcı kalmazsa oda kapanıyor.

Oynatıcı oda oluşturma/katılma, davet kodu paylaşma, lider devri ve ayrılma
akışlarını içeriyor. İki saniyelik bounded rapor; hedef seek/pause yeteneğini,
oynatma konumunu ve son ölçülen gidiş-dönüş süresini Core'a iletiyor. Core,
lider komutunun sunucu zamanına göre beklenen konumunu hesaplayıp yalnız
tolerans dışındaki takipçiye play, pause veya seek-and-play yönergesi veriyor;
uyumsuz alıcıyı desteklenmiyor olarak açık bırakıyor. `de9200f8`, `3fc14af3`
ve `491de127` dilimleri odaklı Python py_compile/import/route smoke, Flutter
analyze ve diff kapılarından geçti. Kullanıcının kararı gereği özellik testleri
son toplu doğrulama evresine bırakıldı. F21 **uygulama tamamlandı · test
bekliyor**; sayaçlar **37/125 (%29,6)** ve **3/63 (%4,8)** olarak değişmedi.
Gerçek iki Client→Core→Jellyfin E2E, gecikme toleransı ölçümü, farklı fiziksel
alıcılar, bağımsız inceleme ve exact-head CI açık kalıyor.

### 27 Eylül F25 jenerik ve kapanış atlama — uygulama tamamlandı, test bekliyor

F25 tek çalışma dalında tamamlandı. Oynatıcı, güncel Jellyfin öğesini önce
Core katalog otoritesinden çözüp `MediaSegments` işaretlerini yalnız izole
worker üzerinden okuyor. Public ve private sözleşmeler hesap, oturum ailesi,
kurulum, snapshot, Jellyfin servis revision'ı, öğe ve medya anahtarını birlikte
bağlıyor. En fazla 32 ham işaret kabul ediliyor; oynatıcıya yalnız sıralı,
çakışmayan ve süre sınırları içindeki en fazla sekiz Intro/Outro aralığı
aktarılıyor. Desteklenmeyen endpoint, boş sonuç ve bozuk/farklı sözleşme ayrı
fail-closed durumlar olarak kalıyor.

Flutter oynatıcı yalnız doğrulanmış aralık aktifken “Jeneriği atla” veya
“Kapanışı atla” düğmesini gösteriyor ve ancak açık kullanıcı eylemiyle aralığın
sonuna gidiyor; otomatik atlama yok. `9cc7a491` kaynak dilimi odaklı Flutter
analyze, Python py_compile, import/route smoke ve diff kapılarından geçti.
Kullanıcının kararı gereği özellik testleri son toplu doğrulama evresine
bırakıldı. Bu yüzden F25 kuyrukta **uygulama tamamlandı · test bekliyor**;
sayaçlar **37/125 (%29,6)** ve **3/63 (%4,8)** olarak değişmedi. Gerçek
Jellyfin Client→Core→worker E2E, bağımsız inceleme, exact-head CI ve gerçek
eklenti/sürüm kabulü açık kalıyor.

### 27 Eylül F26 oynatma kalitesi danışmanı — uygulama tamamlandı, test bekliyor

F26 tek çalışma dalında tamamlandı. Yerel Jellyfin oynatıcı kaynak codec'i,
bit hızı, çözünürlük, HDR aralığı ve sunucunun direct play/remux/transcode
kararını sürümlü kanıta dönüştürüyor. Android alıcı köprüsü decoder MIME
türlerini, ekran çözünürlüğü/HDR türlerini ve NetworkCapabilities bağlantı
tahminini bounded bir snapshot olarak bildiriyor; bu ağ değeri ölçülmüş aktarım
hızı sayılmıyor. Core danışmanı hesap/oturum/ev yetkisini doğruluyor, eksik
telemetriyi açık gap kodlarıyla döndürüyor ve yalnız öneri üretiyor; oynatma
kalitesini otomatik değiştirmiyor. Uzak Jellyfin hedeflerinde de güncel oturumun
PlayMethod, kaynak ve transcoding gözlemi aynı hedef revision'ına bağlandı.

`969d1d1c`–`ed530197` arasındaki dilimler odaklı Flutter analyze, Python import/
py_compile ve Android `compileDebugKotlin` kapılarından geçti. Kullanıcının
kararı gereği özellik testleri son toplu doğrulama evresine bırakıldı. Bu yüzden
F26 kuyrukta **uygulama tamamlandı · test bekliyor** durumunda; sayaçlar
**37/125 (%29,6)** ve **3/63 (%4,8)** olarak değişmedi. Gerçek Jellyfin/Android
alıcı E2E, bağımsız inceleme, exact-head CI ve fiziksel codec/HDR/ağ kabulü
açık kalıyor.

### 27 Eylül F31 haftalık menü yazılım kabulü

F31'in exact `4f9e03516248a64c630f58abadb9b9e8efe589dd` kaynağı porsiyon ve
birim modeli, Türkçe menü, kişi/ev otoritesi, revision-safe düzenleme ve
Home Assistant alışveriş listesine açık hedef seçimi ile ikinci onaylı,
idempotent aktarımı tamamladı. Loopback Client→Core ve gerçek HA action
fixture'ları geç cevap, route/account/lifecycle kaybı, stale CAS, yinelenen
istek ve action-owner değişiminde fail-closed davranışı doğruladı. Odaklı paket
46 testi geçti; bağımsız RED/GREEN incelemesi açık P1/P2 bulmadı.

Android Build [`35879827342`](https://github.com/ersingundem/larenor/actions/runs/35879827342)
ve Security [`35879826820`](https://github.com/ersingundem/larenor/actions/runs/35879826820)
aynı exact kaynakta başarılı oldu. F31'in o tarihteki tek kuyruk engeli B3,
S08.8 ve S08.11'in kabulüyle artık tamamlandı. F31 `done`; sayaç
**35/125 (%28,0)** ve seçili özellik kabulü **1/63 (%1,6)** oldu. Gerçek
Home Assistant ve tablet yolculuğu `MANUAL.SERVICES`/`MANUAL.TABLET` altında
ayrı kalır. [Kapanış kanıtı](testing/f31-meal-edit-handoff.tdd.md).

### 27 Eylül K12 sınırlı watchdog yazılımı — exact CI bekliyor

WebPanel'in yerel beş dakikalık recovery bütçesi artık `tooSoon` ile gerçek
`exhausted` sonucunu ayırıyor. İlk durum kalıcı deneme sayacını tüketmiyor;
üç açık kurtarma sonrasındaki doğal dördüncü istek durable gate'e ulaşıp tek
`recoveryBlocked` kaydı oluşturuyor, yeni renderer açmıyor ve Retry yerine
48 dp güvenli bakım eylemini gösteriyor. Eylem yalnız içeriksiz 30 günlük
sayaçları ve CSV önizlemesini sunan yerel bakım ekranını açıyor. Otomatik
yeniden bağlanma, force-stop sonrası dirilme veya komut replay yolu yok.

EN/TR, 600 piksel ve 2x metinle gerçek dört denemelik akışı içeren odaklı
watchdog/maintenance/WebPanel paketi **55/55** geçti; dokuz üretim/test dosyası
için dar analiz temizdi. Bağımsız final P1/P2 incelemesi blocker bulmadı. K12
`awaiting_ci`; final tek-dal exact CI geçmeden `done` sayılmadığı için sayaçlar
**35/125 (%28,0)** ve **1/63 (%1,6)** kalır. Fiziksel process-death/DeX/uzun
bekleme `MANUAL.KIOSK` altında ayrıdır.
[TDD ve kabul kanıtı](testing/k12-watchdog-local-usage-foundation.tdd.md).

### 27 Eylül K10 sınırlı yerel sensör yazılımı — exact CI bekliyor

K10 artık doğrulanmış 1000..10000 ms örnekleme aralığını yalnız politika
katmanında seyrekleştirmekle kalmıyor; Android light, accelerometer ve proximity
kayıtlarına doğrudan 1.000.000..10.000.000 mikrosaniye olarak iletiyor.
`KioskBridge` üretim varsayılanlarını koruyan package-internal host/focus seam'i
ile başlatma, pencere/DeX odağı kaybı ve resume yetkisi kaybındaki exact native
`stop` davranışını test edilebilir hale getirdi.

Odaklı Android politika/bridge paketi **12/12**, Flutter model/lifecycle/tablet
paketi **24/24** geçti; dar Flutter analizi temizdi. K10 `awaiting_ci`; final
tek-dal exact CI ve kapanış incelemesi olmadan sayaçlar **37/125 (%29,6)** ve
**3/63 (%4,8)** kalır. Gerçek OEM sensör/izin davranışı ile 24 saat pil/termal
ölçümü `MANUAL.KIOSK` altında ayrıdır.
[Kabul kanıtı](testing/k10-local-sensor-tablet.tdd.md).

### 27 Eylül F06 atfedilebilir işlem açıklaması yazılım kabulü

F06'nın exact `2169dd6fd9e3a8b3274413040f2b575600e38540` kaynağı kullanıcı,
kural, servis, komut ve sonucu aynı iz kimliği altında gösteriyor; legacy ve
`unknown` olaylarda zaman yakınlığından neden üretmiyor. Gerçek loopback
Client→izole Core yolu, ev/kullanıcı yetkisi, bozuk cursor/attribution,
iptal/geç cevap ve limit sınırlarını kapalı davranışla doğruladı. Exact kaynakta
odaklı Server **12/12**, Client model/UI/HTTP **36/36** geçti; kayıtlı birleşik
regresyon Server **450/450** ve Client `core_ha` **252/252** idi. Bağımsız
saldırgan inceleme açık P1/P2 bulmadı.

Android Build [`35527450313`](https://github.com/ersingundem/larenor/actions/runs/35527450313),
Security [`35527450077`](https://github.com/ersingundem/larenor/actions/runs/35527450077)
ve Server Container [`35527450252`](https://github.com/ersingundem/larenor/actions/runs/35527450252)
aynı exact SHA'da başarılıydı. B0, B5 ve B3 bağımlılıkları artık tamamlandığı
için F06 `done`; sayaç **36/125 (%28,8)** ve seçili özellik kabulü
**2/63 (%3,2)** oldu. Dış ankora dayalı genel journal bütünlüğü F20'de, gerçek
servis/tablet koşulları MANUAL kapılarında açık kalır.
[Kabul incelemesi](f06-attribution-acceptance-review-2026-09-20.md).

### 27 Eylül F34 QR etiketli ev envanteri yazılım kabulü

F34'ün exact `9295ee46aef97816e166c657caa75019c4e8ee9f` kaynağı ile main'deki
`a1fc2d7fe26830a9dbd758d1e69ac6647951a564` squash commit'i aynı stable
patch-id'ye sahip. Sabit envanter kimliği, şifreli katalog, oda/cihaz/belge
bağlantısı, yetki, bozuk/yabancı QR, sayfalama ve authenticated cursor sınırları
gerçek loopback TCP/HTTP izole Core yolu ile sınandı. Client, tablet, yazdırılabilir
etiket paylaşımı ve Core paketi exact kaynakta **29/29** geçti; bağımsız final
inceleme açık P1/P2 bulmadı.

Android Build [`35873820006`](https://github.com/ersingundem/larenor/actions/runs/35873820006)
ve Security [`35873818998`](https://github.com/ersingundem/larenor/actions/runs/35873818998)
aynı exact SHA'da başarılıydı. B0, B3 ve B5 tamamlandığı için F34 `done`;
sayaç **37/125 (%29,6)** ve seçili özellik kabulü **3/63 (%4,8)** oldu.
Fiziksel kamera taraması, tablet ve gerçek paylaşım/yazdırma hedefleri MANUAL
matrisinde açık kalır. [Kapanış kanıtı](testing/f34-software-closure-2026-09-27.md).

### 24 Eylül S09.3 yazılım kabulü

PR #491 exact `8113e8e456f36abca19b2eb8e3d4296a60faeef4`
kaynağında exact installed-state/host-fact preflightini, admin ve route sahibi
salt okunur Client kaynak incelemesini, packaged Core/component health
receiptlerini ve gerçek native clean-install→upgrade→fresh-process recovery
zincirini birleştiriyor. Exact ancestor Git nesnelerinden materialize ediliyor;
current sürüm force-recreate ediliyor; Core ve tüm managed component writable
mountları random bounded sentinel ile korunuyor. Post-effect kesinti ikinci
süreçte effect replay olmadan uzlaştırılıyor ve cleanup yalnız doğrulanmış
receipt ile descriptor-revalidated owned roots üzerinde çalışıyor.
Fresh-process recovery, retained Compose proje kimliğini benimsedikten sonra
current configi yeniden render edip kanıt digestini yeniliyor. Public
installation phase kanıtı her embedded runtime receiptini kendi digestine,
upgrade/restart Core kimliğini birbirine ve current component kimliklerini dış
initial/restart receiptlerine bağlıyor.

Yerel exact kaynak **64/64 Python/native sözleşme** ve **12/12 Client widget**
testini geçti. Security policy, Python derleme, commit-progress ve diff kapıları
temizdi; iki bağımsız final inceleme P1/P2 blocker bulmadı. Önceki exact
`69173ecd` native run `36038916185`, iki mimaride 59/59 sözleşme testinden
sonra hosted runner yaklaşık 14 GiB sağladığı için production 147456 MiB
aynı-cihaz preflightinde pull/create öncesi fail-closed durdu. Current exact
yalnız native acceptance driverında gerçek device başına gereken kapasiteyi
fixture eder; production `LocalHostFacts` ve deployment politikası değişmedi,
public receipt `contract_fixture`/`capacityVerified=false` işaretlidir. İkinci
exact `84f4abdf` install aşaması kodunu genel reconcile koduyla maskelediğini
gösterdi. Exact `3007994b` reconcile exception yolunu düzeltti; native run
`36040926865` ise empty reconcile sonucunun final receipt doğrulamasında aynı
kodu yeniden maskelediğini kanıtladı. Current exact bu yolu da düzeltir; yalnız
allowlistli aşama kodunu private ayrıntı sızdırmadan korur, unknown/malformed
sonuçları sabit reconcile kodunda tutar. `89fbfcc6` native run `36041571640`
ardından gerçek `unified_manifest_invalid` kökünü gösterdi: archived Compose
göreli Dockerfile yolunu checkout CWD'sine bağlıyordu. Current exact yalnız
canonical archived context altındaki literal `server/Dockerfile` yolunu kabul
eder; absolute/traversal/foreign/symlink yollar fail-closed kalır. Security
`36045879756`, dual-architecture Unified Media Stack Native Acceptance
`36045879876` ve Android Build `36045880167` attempt 2 geçti. Failed-only
Server shard-3 job `107796968207` ile aggregate job `107801997329`; native
amd64 job `107789265813` ile arm64 job `107789265906` başarıyla tamamlandı.
Kaynak `b7a82258f11a6bd46f00d9a8561dcb2b895fb030` olarak squash birleşti ve
`origin/main` ancestry'sinde doğrulandı. Source/squash aggregate stable patch-id
`9b614a3dcf5e3703ab6ee953956acfd4afeb5d3f` eşleşti. S09.3 `done`; sayaç
**34/125 (%27,2)** ve seçili özellik kabulü **0/63** kaldı.
[Kapanış kanıtı](testing/s09-3-clean-install-upgrade-recovery.tdd.md).

### 24 Eylül K08 sınırlı web→native köprü yazılım kabulü

PR #487 exact `2a39ca2be54a51e64a1c6517dc8c37ffe370045b`
kaynağında sürümlü exact HTTPS üst-origin/method politikası, main-frame
Android WebMessage transportu ve monotonik tek kullanımlık onay zinciri;
production TTS, açık kullanıcı onaylı bounded PDF print ve görünür QR etkilerine
bağlandı. Exact Core/home/account/session/policy/route/lifecycle sahibi her etki
öncesi yeniden doğrulanıyor. Logout, replacement, background, timeout,
renderer-loss, permission denial, capability drift ve gecikmiş bind eski effect
veya receipt yayımlamadan terminal kapanıyor.

Yerel grouped paket **185/185 Flutter** ve **30/30 Robolectric** testi geçti;
focused analyze, format, security, queue, commit-progress ve diff kapıları
temizdi. Bağımsız final P1/P2 incelemesi fresh per-render owner, delayed-bind,
QR cancellation ve replay sınırlarında blocker bulmadı. Android Build
`35988043289` statik analiz, dört Flutter ve dört Server shardı ile aggregate,
debug APK ve API 35 emulator yolculuğunu; Security `35988042981`
secret/platform/dependency kapılarını geçti. Kaynak `a87d1bb3` olarak squash
birleşti; aggregate stable patch-id
`49dd58e007084eeff56f383b3d4f3e46b6b6f860` eşleşti. K08 `done`; kuyruk
**33/125 (%26,4)**. Fiziksel Huawei/DeX/TalkBack/OEM/DPC yolculukları ayrı
MANUAL kapıdır.
[Kapanış kanıtı](testing/k08-web-native-bridge-foundation.tdd.md).

### 24 Eylül S08.11 yazılım kabulü

PR #488 exact `5e440235b6f7cc39cb638ea5ac9fd2f033a667f1`
kaynağında Core dashboard yedek şeması v3 capture, preview, restore ve recovery
journalını exact `coreId/homeId/userId` sahibine ve tek scoped anahtara bağladı.
Aynı URL'de Core A→B değişimi A katalog/arama sonuçlarını emekli ediyor; A
yedeği B kapsamında preview/apply olmadan reddediliyor ve iki scoped anahtar da
değişmiyor. A'ya dönüş, gerçek restore ve `ConfigurationScope` remount sonrası
kartlar güncel revision refetch edilene dek inert; logout ve geç callback'ler
eski sonucu tekrar yayımlamıyor. Dart ve Python vault sınırları retired upload
authority ile malformed/future v3 sahibini fail-closed reddediyor.

Yerel kabul 378 Flutter backup/vault, 49 odaklı Core replacement/restore ve 39
Python vault testiyle tamamlandı. Final bağımsız denetim 92 controller/account/UI
ve 8 çapraz akış testini yeniden doğruladı; P1/P2 blocker bulmadı. Exact Android
Build `35966881025` attempt 2 statik analiz, dört Flutter shardı ve aggregate,
dört Server shardı ve aggregate, debug APK ve API 35 emulator yolculuğunu;
Security `35966880542` secret/platform/dependency kapılarını geçti. İlk Server
attemptindeki ilişkisiz Docker-adapter testi tek kez false döndü; aynı test
izole + 12 seri tekrarda 13/13 geçti ve failed-job rerun aynı SHA'da kod
değişmeden yeşil oldu. Kaynak `1d603365` olarak squash birleşti; aggregate
stable patch-id `7d9be065b6c8a6bdc6cbb95ab48868511d988fd4` eşleşti. S08.11 `done`;
kuyruk **32/125 (%25,6)**. Fiziksel HomePod, Cast, Apple TV, Huawei, DeX ve OEM
yolculukları ayrı MANUAL kapılardır.
[Kapanış kanıtı](testing/s08-11-authority-crossflow-closure.tdd.md).

### 24 Eylül S08.8 yazılım kabulü

PR #480 exact `ff55f5141ad3f686e73511465ff057f14b18495a` kaynağında
verified veya çözümlenmemiş Core evlerini provider-free katalog ve hesap satırı
denetleyicilerine yönlendirdi; yalnız exact Direct ev yerel medya ağacını
kurabiliyor. Resolved-import mimari kapısı dashboard, hub, arama, casting,
hedef ve ayar girişlerinde doğrudan Jellyfin/Music Assistant/Arr/Seerr client
kurulumunu reddediyor. Gerçek loopback akışı browse, recent ve resume verisinin
restart sonrasında güncel hedefle doğrulandığını; logout ve aynı URL'de Core
değişiminde eski sonuç yayımlanmadığını kanıtlıyor.

Yerel kanıt 3/3 mimari, 81/81 birincil Flutter ve 54/54 aktif yüzey
regresyonundan oluşuyor. Bağımsız full-diff inceleme P1/P2 blocker bulmadı.
Exact Android Build `35950583150` statik analiz, dört Flutter shardı, dört
Server shardı, iki aggregate kapı, API 35 emülatör ve debug APK'yı; Security
`35950582810` dependency/platform/secret kapılarını geçti. S08.8 `done`;
kuyruk **28/125 (%22,4)**. Gerçek HomePod, Cast ve Apple TV yolculukları
`MANUAL.MEDIA` altında ayrı kalır.

### 24 Eylül K03.remaining yazılım kabulü

PR #474 exact `ac8e1af6c5564fbc41eb5ea50d15241d01da2a87` kaynağında
anonymous, bounded alt-kaynak GET transportunu, her redirectte exact-origin
kontrolünü ve document-start WebSocket/EventSource/WebTransport/Worker/
SharedWorker kapısını birlikte doğruladı. Owned transport cancellation,
streaming/declared-length kota ve attachment retirement testleri; top,
same-origin iframe, opaque/delayed frame ve reload API 35 matrisiyle birlikte
geçti. Bağımsız exact-tree review kalan P1/P2 yazılım blockerı bulmadı.

Android Build `35941771379` emulator yolculukları, dört Flutter shardı, statik
analiz, dört Server shardı ve aggregate kapısı ile debug APK'yı; Security
`35941771192` dependency/platform/secret kapılarını aynı exact kaynakta geçti.
Exact kaynak squash `7211a6ff` olarak main'e birleşti. Deterministic kabul manifesti kritik
production/test guard markerlarını ve bu exact CI setini current tree üzerinde
yeniden doğrular. K03.remaining `done`; kuyruk **27/125 (%21,6)**. Fiziksel
Android, DeX, Huawei WebView, OEM renderer, DPC, force-stop, çevre birimi ve
gerçek-site davranışı MANUAL kalır.

### 24 Eylül S09.2 yazılım kabulü

PR #483 exact `34870d703178ba5ca4629e3d887d74aca4475d5a`
kaynağında root-only offline restore runtime'ı, Core ile managed component için
tek durable `pending`→`released` kararı ve authenticated restart uzlaştırması
tamamlandı. Yanlış parola, kesik/bozuk imza, sürüm/şema uyumsuzluğu, authority
ve deadline driftinde hedef yayımlanmıyor. External released checkpoint
başarısızlığı journal'ı koruyor; başarılı restart replay journal'ı temizliyor ve
retained authority tam bir kez bırakılıyor.

Yerel paket **159 test topladı: 157 geçti ve 2 beklenen Darwin native-fixture
skip**; son recovery/product paketi **24/24**, bağımsız adversarial replay
regresyonu **1/1** geçti. Bağımsız final P1/P2 incelemesi blocker bulmadı.
Android Build `35961861609` statik analiz, dört Flutter ve dört Server shardı,
aggregate kapılar, debug APK ve API 35 emulator yolculuğunu; Security
`35961861319` secret/platform/dependency kapılarını; native kabul
`35961861335` gerçek root CLI/runtime zincirini `linux/amd64` ve
`linux/arm64` üzerinde geçti. Kaynak `5ea97117` olarak squash birleşti ve
aggregate stable patch-id `553bc783d78b8bfcf0c68a7f7900ef87491b8d7a`
eşleşti. S09.2 `done`; kuyruk **31/125 (%24,8)**. Temiz kurulum/yükseltme,
Client restore ve component health S09.3'te ayrı kalır.
[Kapanış kanıtı](testing/s09-2-empty-component-restore.tdd.md).

### 24 Eylül K08 ve S08.11 birleşik ilk ara teslimi

PR #484 exact `b7f957d52146dae8c357ede6063bc57f70a2baef`
kaynağında sürümlü exact-origin/method politikasını frame-aware Android
WebMessage transportuna ve monotonik 30 saniyelik kullanıcı onayına bağladı.
Android Build `35962472970`, Security `35962472693`, API 35 emülatör ve
bağımsız P1/P2 incelemesi geçti; kaynak `e03022e8` olarak squash birleşti.
Kaynak/squash aggregate stable patch-id
`bfa9a096b0312a9f989df31cf355b2adca44eb53` eşleşti. Normal production çağrısı
yetkili TTS/print/QR effect portu sağlamadığından K08 bu aşamada `pending`
kaldı; üretim etkileri ve yazılım kapanışı daha sonra PR #487 ile yukarıdaki
exact kanıtta tamamlandı. Fiziksel Huawei/DeX ayrıca MANUAL kaldı.

PR #485 exact `6af3dfb8a2ada8c0ddde32991b3b6e2f63d07129`
kaynağında yetkili Core kaynaklarını arama, oda ve kart yüzeylerine bağladı;
same-runtime eski veriyi inert tuttu, logout temizliğini ve strict backup
binding doğrulamasını ekledi. Android Build `35962916222`, Security
`35962916059`, API 35 emülatör ve bağımsız P1/P2 incelemesi geçti; kaynak
`8032e5a0` olarak squash birleşti. Kaynak/squash aggregate stable patch-id
`ceed5f6b195a17d80741f0974b797b87fe355713` eşleşti. Same-URL Core switch,
process restart, gerçek restore rebind ve hesap değişimini üç yüzeyde birlikte
kanıtlayan çapraz E2E eksik olduğundan S08.11 `pending` kalır. Bu iki ara teslim
hiçbir kuyruk kabulünü tek başına kapatmadı; sayaç **31/125 (%24,8)** ve seçili
özellik kabulü **0/63** olarak değişmedi.

### 24 Eylül S09.1 yazılım kabulü

`a083bca6`, mevcut authority-bound isolated capture lease'ini gerçek ayrıcalıklı
Server entrypoint'ine ve Linux btrfs read-only/COW engine'ine bağladı. Exact
generation intent'i ilk filesystem etkisinden önce 0600 journal'a yazılıyor;
kesinti veya başarısız release journal'ı restart cleanup için koruyor. Source
path/inode değişimi, yazılabilir snapshot, malformed journal ve journal dışı
capture-root içeriği fail-closed. Odaklı paket **15/15**, gruplanmış component
backup paketi **103 geçti / 1 açıkça native-fixture skip**, workflow sözleşmesi
**2/2** geçti. Dar native workflow gerçek btrfs snapshot/release/restart
zincirini GitHub-hosted `linux/amd64` ve `linux/arm64` üzerinde çalıştırıyor.

PR #482 exact `e84253208d8d2989e9f647fcdf13949d257c4e99` kaynağı DB,
vault key, yapılandırma ve managed component payloadlarını aynı immutable
generation altında tuttu; encrypted Client export aynı generation header ve
digest receipt'i doğrulanmadan OS-owned destination'ı commit etmiyor. Exact
native CI `35952609533` hem `linux/amd64` hem `linux/arm64` için geçti. Bağımsız
P1/P2 incelemesi mixed/malformed generation, lifecycle drift ve partial
destination yollarının fail-closed kaldığını doğruladı. Üretim commitleri main
`21272df4` üzerine restack edilirken dokuz stable patch-id değişmedi. S09.1
`done`; kuyruk **30/125 (%24,0)** ve seçili özellik kabulü **0/63** kalır.

### 24 Eylül birleşik teslim kanıtı — PR #456–#462

Açık PR kuyruğu boşaltıldı. PR #457–#462'nin exact kaynakları zorunlu
current-head CI ve API 35 emülatör kapısından sonra squash merge ile main'e
girdi; her exact rollup 29 başarılı ve 6 beklenen skip ile kapandı. Kaynak ve
squash stable patch-id eşitliği ile main ancestry'si
ayrı ayrı doğrulandı. Birleşen branch ve worktree'ler temizlendi. Bu dilimler
S08.8, S09.1 ve K03'ün kalan sınırlarını daralttı; bu birleşme anında hiçbir
kuyruk düğümünün bütün kabul ölçütleri kapanmadığı için sayaç **26/125 (%20,8)**
kaldı. Sonraki PR #474 exact kabulü K03.remaining'i yukarıdaki kanıtla kapattı.

| PR / alan | Exact head → merge | Kanıt ve kalan sınır |
| --- | --- | --- |
| #456 / Docs | `a78f10e0` → `7d9bee7c` | #448–#455 exact teslim kanıtı ve değişmeyen sayaçlar birleşik metne taşındı. |
| #457 / K03 | `c816cfae` → `8fdfc36e` | 113 Flutter + 13 Robolectric; boolean-only native SAF receipt, exact iptal/partial cleanup, otorite hatası sınırı ve renderer retirement. Subresource redirect ile WebSocket/worker egress'i için owned transport ve fiziksel kabul açık. |
| #458 / S08.8 | `8adc49f8` → `8f2ce21b` | 24 + 69 servis bağlantısı testi ve 5 büyük metin regresyonu; sır göstermeyen, açık onaylı eski Jellyfin bağlantı geçişi. Bu PR anında direct runtime tüketicileri açıktı; #480 kapattı. |
| #459 / S08.8 | `1d9fa7fc` → `31b78659` | 94 Flutter; exact integer schema/revision, türlenmiş resource envelope, tuple/TTL/kota ve Core değişiminde fail-closed önbellek. |
| #460 / S09.1 | `bc73b4ab` → `9ccd6fe4` | 88 gruplanmış test; read-only/COW capture lease, tek generation, shared-writer ve drift reddi, bir kez release. Privileged Linux engine ve iki mimarili native kabul açık. |
| #461 / S08.8 | `9fe0875d` → `ff8ebf10` | Gerçek loopback medya ürün yolu 2/2: katalog araması → sağlayıcı kanıtı → player intent/komut → restart/logout/başka Core retirement; device-local Jellyfin çağrısı yok. |
| #462 / S08.8 | `0690ee84` → `9286cebf` | 28 odaklı müzik testi; retained Music Assistant → Spotify araması → HomePod hedefi → exact queue/readback/receipt → logout retirement; ayrı MA veya HA WebSocket yolu yok. |

S08.8'in o aşamada açık kalan direct medya UI/runtime ve merkezi
browse/recent/resume sınırları PR #480 ile yukarıdaki exact kabulde kapandı.
S09.1'in lease sözleşmesi production provider, privileged Linux capture engine,
amd64/arm64 native kabulü ve bütün DB/anahtar/yapılandırma/bileşen veri
sınırlarının aynı generation kanıtıyla tamamlandı. K03'ün SAF, external action,
renderer yaşam döngüsü, owned subresource transportu ve document-start dynamic
egress sınırı yazılım kabulünü tamamladı; fiziksel tablet/DeX/OEM kabulü ayrı
MANUAL kapıda açık.

### 23 Eylül aktif teslim kanıtı — PR #448–#455

PR #448 ve #449 ilerleme metnini kanıtlı sayaçlarla birleştirdi. Sonraki altı
ürün dilimi S08.8 ve S09.1'in kalan yazılım sınırlarını daralttı; hiçbir dilim
tek başına ilgili kuyruk düğümünün bütün acceptance ölçütlerini kapatmadığı için
sayaç **26/125 (%20,8)** ve seçili özellikler **0/63** kaldı.

| PR / alan | Exact head → merge | Kanıt ve kalan sınır |
| --- | --- | --- |
| #448 / Docs | `45deec1e` → `d5212b3c` | Sayaçlar ve #439/#443–#447 exact kanıtı tek güncel teslim metninde birleştirildi. |
| #449 / Docs | `98ca3b34` → `7c2e9613` | Hareketli main adı yerine stable ancestry kaynağı kullanıldı. |
| #450 / S09.1 | `5a9b413b` → `fefdf410` | 232 odaklı test; snapshot kaynakları kalıcı kurulum otoritesine bağlandı. İzole ve tutarlı yedek alma açık. |
| #451 / S08.8 | `180dcc04` → `36c5395f` | 45 Server + 20 Flutter; tek kullanımlık Core playback intent/receipt ve tablet hedef onayı. Üretim worker'ı ve önbellek açık; fiziksel alıcı ayrı `MANUAL.MEDIA` kapısı. |
| #453 / S08.8 | `f12c37b4` → `cc93b18a` | 65 Flutter; eski Jellyfin dil tercihleri yalnız açık EN/TR onayı ve güncel route/session ile taşınıyor. |
| #452 / S09.1 | `aaf2991e` → `8cfe43ef` | 415 geçti, 2 platform skip / 417 toplandı; Docker inspect/pause/unpause ve belirsiz-etki uzlaştırması. İzole salt okunur/COW yedek alma açık. |
| #454 / S08.8 | `73272091` → `a9bf847b` | 35 odaklı + 72 gruplanmış; worker, şifreli Jellyfin yetkisi, işlem öncesi/sonrası kesinlik, türlenmiş IPC ve stream temizliği. Exact CI 41/41 geçti. |
| #455 / S08.8 | `a13f93fc` → `c8088367` | 51 Flutter; güncel yetki doğrulamalı Client önbellekleri, yaşam döngüsü temizliği ve sorgu/tür/limit kanıtı. |

#454 ve #455 kaynak/squash farklarının stable patch-id eşitliği doğrulandı;
ikisi de main ancestry'sine alındı ve eski headlere ait yeşil sonuçlar kabul
edilmedi.

### 23 Eylül birleşik teslim kanıtı — PR #439, #443–#447

Stable main `36e05f9a`, altı bağımsız dilimin exact kaynaklarını ve birleşme
sonuçlarını içeriyor. Bütün zorunlu statik analiz, dört Flutter shardı, dört
Server shardı, API 35 emülatör yolculukları, debug APK, Security ve yönetilen
medya native kabul işleri ilgili exact headlerde geçti.

| PR / kuyruk alanı | Exact head → merge | Odaklı test ve inceleme | Exact CI |
| --- | --- | --- | --- |
| #439 / F28 | `92253ca1` → `38cefa3a` | 29/29; provider, URI ve worker-scope bağımsız RED/GREEN denetimi | Android `35878111557`, Security `35878111086` |
| #443 / S08.8 | `a150291f` → `9212c3f7` | 25 Server + 18 Flutter; tek hedef, schema ve geç authority RED/GREEN denetimi | Android `35878923924`, Security `35878923225` |
| #444 / F24 | `900c0b74` → `193a6c77` | 71 Flutter + 15 Server; session-family rotation ve legacy sözleşme denetimi | Android `35882571258`, Security `35882570560` |
| #445 / F31 | `4f9e0351` → `9fedf43b` | 46 odaklı; Home Assistant action-owner değişimi RED/GREEN denetimi | Android `35879827342`, Security `35879826820` |
| #446 / S09.1 | `12c6ddf0` → `c9e7cc08` | 31/31; cross-UID socket, provider hatası ve release-ACK denetimi | Android `35884049752`, Security `35884049756` |
| #447 / S09.1 | `11139268` → `36e05f9a` | 49/49; bounded enumeration P2 RED/GREEN ve exact-head yeniden inceleme | Android `35887465363`, Security `35887464912` |

Bu birleşmeler kendi tarihlerinde sayaç artırmadı. Sonraki #459/#461/#462
exact cache ve merkezi katalog→sağlayıcı→oynatıcı→kuyruk ürün E2E'sini ekledi;
S08.8'in o tarihte açık direct UI/runtime ve browse/recent/resume eşliği PR
#480 ile sonradan kapandı. F28 chapter eylemleri, bookmark, sleep timer ve MediaSession'ı; F24
sağlayıcı consent/kota ile gerçek renderer/subtitle-engine kanıtını bekliyor.
F31'in kendi ürün, test, inceleme ve CI kanıtı tamamlandı; o teslim anında `B3`
bağımlılığındaki S08.11 `pending` olduğu için validator kapanışı reddediyordu.
S08.11 daha sonra #488 ile üstteki exact kanıtta kapandı; F31 de 27 Eylül
kapanış kaydıyla kabul edildi. #460 S09.1 izolasyon
lease'ini ekledi; privileged Linux engine,
iki mimarili native kabul ve birleşik generation arşivi daha sonra #482 ile
üstteki exact kanıtta kapandı. Geri yükleme/kurtarma S09.2 de PR #483 ile
kapandı; temiz kurulum/yükseltme, Client geri yükleme ve component health
S09.3 ile yukarıdaki exact kanıtta kapandı.

[PR #447](https://github.com/ersingundem/larenor/pull/447) exact
`11139268` ile bounded managed-volume provider dilimini tamamlayıp `36e05f9a`
olarak birleşti. Bağımsız P2
incelemesindeki RED `3f5fba8e`, dizin girdilerinin sınır uygulanmadan önce
toplanıp sıralandığını gösterdi; GREEN `28ac68d4` enumeration'ı sıralama öncesi
sınırladı ve odaklı paket **49/49** geçti. Bu dilim S09.1'in tutarlı ve izole
yedek alma kapılarını tek başına kapatmadığından kuyruk
**26/125 (%20,8)**, seçili özellik kabulü **0/63** kalır.

### 24 Eylül K07 eşleştirilmiş tablet yazılım kabulü

Exact `0a6c2b296714eda0896dba3b277e331f129e38a6` kaynağında açık secure enrollment, current Core/egress ve
foreground runtime owner zinciri; TLS-only MQTT ile SUBACK ve matching QoS 1
PUBACK; replay/rate/scope kalıcılığı; native `lockKiosk` ile retained Dart
`refreshDashboard`/`syncProfile` komutları birlikte doğrulandı. Malformed fakat
finite DateTime-aralığı dışındaki deadline artık parserdan kaçmadan exact
`invalid_mqtt_command` ACK üretiyor.

Bağımsız P1/P2 review blocker bulmadı. 67 odaklı Flutter, 10 Core ve 4 validator
testi geçti. Android Build `35953409201` statik analiz, dört Flutter shardı,
dört Server shardı ve aggregate, API 35 emülatör ve debug APK'yı; Security
`35953408908` secret/platform/dependency kapılarını aynı exact kaynakta
geçti. Deterministic manifest production/test markerlarını, review ve CI SHA'sını
fail-closed doğrular. K07 `done`; kuyruk **29/125 (%23,2)**. Fiziksel Huawei,
DeX, TalkBack, OEM/DPC, gerçek broker kurulumu ve cihaz ölçümleri MANUAL kalır.
[Kapanış kanıtı](testing/k07-software-acceptance.tdd.md).

### REMOTE.COMMON ortak uzak erişim temeli — yazılım kabul edildi

Exact `63a1a33d` kaynağında yerel ve Core profilleri, IP/domain/IPv6/port
doğrulaması, sürümlü güvenli depo, host kimliği ve 15 dakikalık kişisel oturum
lease'i birlikte doğrulandı. PIN, idle, lifecycle, route, profil revision, pencere
ve DeX focus kaybı ile Core sign-in/sign-out/refresh/rebind ve aynı generation
içindeki 401 revoke; SSH, SFTP, tünel, RDP ve VNC panellerini ve tutulmuş
eylemleri kapatıyor. Belirsiz komut veya girdi yeniden oynatılmıyor.

Tam uzak erişim paketi **216 testi** geçti; dört izole gerçek OpenSSH fixture'ı
F63 protokol kabulünde belgeli skip olarak kaldı. Bağımsız exact-head inceleme
temizdi. Android Build `35827908569` statik analiz, dört Flutter shardı, API 35
uygulama yolculukları, Server kapıları ve debug APK'yı; Security
`35827908316` secret, platform ve dependency kontrollerini geçti.
[Kapanış kanıtı](testing/remote-common-closure.tdd.md). REMOTE.COMMON `done`;
kuyruk **26/125 (%20,8)**, seçili özellikler **0/63**. Gerçek host uyumu,
Huawei tablet/DeX ve protokol ayrıntıları F61-F63 ile MANUAL.FEATURES içinde
açık kalır.

### K05 ortam içerik listeleri — yazılım kabul edildi

Exact `9431c911` kaynağında video, PDF ve izinli HTTPS içerikleri için 24 öğe
ve fiziksel 256 MiB offline kota sınırı; bozuk içerik atlama; tek geçişli
decoder hata bütçesi; hareket azaltma; aktif medya sahipliği ve exact-origin
web politikası birlikte doğrulandı. Kesilmiş import orphan'ları temizleniyor;
eksik, yanlış boyutlu veya regular-file olmayan manifest girdileri kapalı
davranıyor. 79 ambient testi, 67 testlik kabul paketi ve bağımsız güvenlik/race
incelemesi geçti. Android Build `35821461533` API 35 gerçek uygulama
yolculukları ve debug APK ile, Security `35821461367` aynı committe geçti.
[TDD ve exact-head kanıtı](testing/k05-ambient-content-lists.tdd.md). K05
`done`; kuyruk **25/125 (%20,0)**, seçili özellikler **0/63**. Fiziksel
decoder, ekran ve OEM kabulü MANUAL kalır.

### Bekleyen PR'ların birleşik kapanışı — PR #328

PR #328, 28 kaynak PR'ın exact head commitlerini merge commitleriyle koruyarak
main `70c667b5` içine aldı. Exact `e154242d` başlığında dört Flutter shardı,
dört Server shardı ve birleşik kapıları, API 35 emülatörde gerçek uygulama
yolculukları, debug APK, Security, SSH, iki mimarili Music Assistant ve birleşik
medya yığını kontrolleri geçti. Bu birleşim anında GitHub'da açık PR kalmadı.

Bu birleşim; aile panosu, rezervasyonlar, ev belgeleri, ev işleri/masraflar,
kamera, enerji/iklim, kat planı, oda varlığı, e-paper, atölye, kiosk ve uzak
erişim için geniş yazılım dilimleri içeriyor. Ancak DeX ikinci ekranda gerçek
ayrı Flutter görev yüzeyi, paketlenmiş oyun yayın motoru, üretim EV/enerji/sulama
sağlayıcıları ve ilgili fiziksel cihaz/servis matrisleri açık. Kuyruktaki tam
kabul ölçütleri karşılanmadan F01–F63 veya S09 düğümleri `done` yapılmadı;
kanıtlı sayaçlar **24/125 (%19,2)** ve **0/63 (%0,0)** olarak güncellendi.

### S07.4 tek kurulum durumu — yazılım kabul edildi

PR #328'in birleşik ağacındaki bağımsız kabul incelemesi, Server'ın ayrı
ürettiği süreç ve entegrasyon durumlarının Client tarafından doğrulanıp sonra
atıldığını buldu. RED tablet testi, `started` süreç ile `unverified`
entegrasyonun aynı satırda açıkça ayrılmadığını gösterdi. `1fcea99a` Client
modelini ve EN/TR kanıt satırını düzeltti; 13 Flutter, 8 Server ve 20 paket/
iki mimarili restart sözleşmesi testi ile kuyruk doğrulaması yerelde geçti.

Client yalnız dört operatör kimliği ve sağlayıcı hesabı yüzeylerine yöneliyor;
dahili servis adresi, token, kurulum, rollback veya komut eylemi açmıyor.
Eksik servisler yedi satırlı kapalı sözleşmede `missing/unknown/unverified`
olarak kalıyor. Çapraz servis Core API testi altı medya servisini birlikte
okuyor; PR #328'in birleşik yığın işi amd64/arm64 restart kapısını geçti.
[Exact-tree inceleme ve TDD kanıtı](testing/s07-4-exact-tree-closure-2026-09-23.md).
PR #330 exact head `223ff08f` üzerinde Android Build run `35812635044`
statik analiz, dört Flutter shardı, dört Server shardı, API 35 gerçek uygulama
yolculukları ve debug APK'yı tamamladı. Security run `35812634919` ile secret,
platform-policy ve bağımlılık kapıları; Unified Media Stack run `35812634855`
ile `linux/amd64` ve `linux/arm64` restart zincirleri geçti. PR #330 main
`814eaeac` içine birleşti. S07.4 `done`, sayaç **24/125 (%19,2)** ve B2
**4/4** oldu; gerçek sağlayıcı, alıcı ve fiziksel ev kabulü manuel sınırda
kalır.

**B5.2 kabulünün tam doğrulanmış birleşik kaynağı: main `e313328f`.** B5.2'nin kişisel
profil Client/Core senkronu birleşik dalda 44/44 odaklı Flutter testini ve
scoped analizi geçti. PR #271 tüm zorunlu Android, API 35 E2E, Server ve
güvenlik kapılarını tamamladı. [B5.2 kapanış kanıtı](b52-personal-profile-software-closure-2026-09-21.md).
Gerçek uzak sunucu ve fiziksel tablet kabulü henüz yapılmadı.

### S08.10 olay, komut ve sınırlı transfer — yazılım kabul edildi

PR #301'in exact CI kabulü main `d0a3a43f` içinde birleşti. Kalıcı olay
zinciri ve bounded ürün transferi, kaynak/yetki/revision kapsamı, kesinti
makbuzu ve Android Client'ın geç yanıt korumalarıyla yazılım kapısını geçti.
[Üç ölçüt ve kapanış kanıtı](testing/s08-10-software-closure-2026-09-21.md).
Kuyruk **23/125 (%18,4)** oldu; gerçek SAF sağlayıcısı ve fiziksel tabletteki
dosya akışı **MANUAL** kalır.

### B5.2 kişisel profil ve hassas oturum — yazılım kabul edildi

Remote Access, bu tablette saklanan profillerle Larenor Core profillerini açıkça
ayırıyor. Core satırları exact Core, ev, hesap, authenticated session-family ve
collection revision ile bağlanıyor. 409 çakışması eski satırı salt okunur stale
duruma getiriyor; kayıp yanıt yeniden yazılmadan doğrulanmış readback ile
uzlaştırılıyor. Parola, token, secret, PIN ve lease alanları kapalı modelde
reddediliyor.

Birleşik dal **44/44** odaklı testi geçti ve PR #271 exact CI kapılarını
tamamladı. Böylece kuyruk **22/125 (%17,6)** oldu. Gerçek RDP/VNC/SSH
oturumları, Huawei MatePad, Samsung DeX, klavye ve TalkBack kabulü MANUAL
yayın matrisinde kalır.

### B5.1 ortak tablet düzeni — yazılım kabul edildi

Ayarlar, Bugün, medya ayrıntıları, Home Assistant cihaz/varlık eylemleri,
Keenetic widget seçimi, Core bağlantısı ve güncelleme yüzeyleri ortak tablet
sayfası, kart, durum kanıtı ve gezinme dilinde birleşti. Eylemler etkin hesap,
route, lifecycle, interaction epoch ve exact servis/cihaz revision sınırında
çalışıyor; kayıtlı bağlantı, erişilebilir servis ve doğrulanmış sonuç ayrı
gösteriliyor.

Son birleşik önizleme **240/240** odaklı testi geçti. PR #259 tüm zorunlu CI
kapılarını tamamladı. Böylece kuyruk **21/125 (%16,8)** oldu. Huawei MatePad,
Samsung DeX, klavye, TalkBack, canlı Home Assistant, medya alıcısı ve Keenetic
kabulü MANUAL yayın matrisinde kalır.

### S07.2 otomatik medya akışı ve S07.3 tek müzik API'si — kabul edildi

Seerr isteği, qBittorrent indirmesi, Sonarr/Radarr içe aktarımı ve Jellyfin
oynatılabilir sonucu tek revision-bound akışta birleşti. Eksik sezon, kısmi
içe aktarma, hardlink/canonical yol, kesinti, idempotent retry ve belirsiz etki
durumları açık ve fail-closed kaldı. Music Assistant tarafında provider setup,
katalog, kuyruk, HomePod/AirPlay/Cast alıcı türleri ve oynatma komutları tek
Larenor Core otoritesinden sunuluyor; ayrı MA adresi veya tokenı istenmiyor.
Şifreli özel anahtar yenilemesi restart, kayıp yanıt, replay, eşzamanlı işlem
ve yetki driftinde kapalı davranıyor.

Birleşik main ağacında 87 odaklı Server/API testi geçti. PR #230 ve #231 tam
zorunlu kapıları, S07.1 de iki mimarili paket yaşam döngüsünü geçti. Bu iki iş
ile kuyruk **20/125 (%16,0)** oldu; gerçek abonelik girişleri, HomePod/Cast
eşleştirme ve fiziksel oynatma MANUAL kapılarında kalır. [Üç kabul ölçütü ve
kanıt](s07-2-s07-3-software-closure-2026-09-21.md).

### S07.1 tek Larenor medya/müzik paketi — kabul edildi

Core, Jellyfin, Seerr, Sonarr, Radarr, qBittorrent ve Music Assistant aynı
canonical Compose/bundle tanımında; exact digest, volume, tmpfs, ağ ve DNS
kimlikleriyle paketlendi. Dahili servis URL/token/parolaları kullanıcı ayarı
değildir. Owned path ve runtime receipt sınırları belirsiz sonucu başarı
saymadan kapanır.

PR #182 headinde 41 zorunlu check ile unified stack ve altı bileşenin gerçek
amd64/arm64 Docker kabulü geçti; main `4e6236e8` üzerinde S07.1 kapandı.
[Üç kabul grubu ve exact kanıt](s07-1-unified-package-acceptance-2026-09-21.md).
Kuyruk **18/125 (%14,4)**, seçili özellik sayacı **0/63**'tür. CasaOS/Proxmox,
sağlayıcı hesabı ve HomePod/Cast kabulü MANUAL kapılarında kalır.

### S06.5 özel bootstrap ve otomatik eşleştirme — kabul edildi

Exact `f78f138c` kaynak ağacı ile main `b38c8ab9` ağacı aynıdır. Bu kaynakta
Seerr 3.4.1, ilk yöneticiden Jellyfin ve Sonarr/Radarr eşleştirmesine, resmi
initialize çağrısından authenticated readback ve restart'a kadar amd64/arm64
gerçek konteynerlerde geçti. Music Assistant 2.10.4 de Core iç yöneticisi,
uzun ömürlü entegrasyon anahtarı, onboarding, provider/player keşfi, playback
readback ve restart zincirini iki mimaride tamamladı.

Kabul üç yazılım ölçütüne bağlıdır: sırların yalnız şifreli Core kaydı ve UID
denetimli private IPC'de kalması; servisler arası adres/anahtar/kütüphane
eşleştirmesinin authenticated readback ile doğrulanması; sabit exact-source
zincirinin amd64/arm64 gerçek süreç makbuzu üretmesi. Kısmi veya belirsiz etki
başarıya yükseltilmez. [Üç ölçüt ve exact kanıt](s06-5-bootstrap-acceptance-2026-09-20.md).

Bu kapanış `installAvailable` değerini açmaz. Altı bileşenin tek dağıtımda
paketlenmesi S07.1'de; CasaOS/Proxmox,
gerçek sağlayıcı hesabı ve HomePod/Cast kabulü MANUAL kapısında kalır. Kuyruk
**16/125 (%12,8)**, seçili özellik kabulü **0/63**'tür.

### S06.6 doğrulanmış sonuç, iptal ve kurtarma — kabul edildi

Ortak yönetici görünümü, altı yönetilen medya servisi için container
create/start makbuzunu authenticated servis sonucundan ayrı gösterir. Restart,
iptal ve belirsiz etki kayıtları salt okunur API tarafından silinmez veya
yeniden yürütülmez; yetki kaybı worker etkisi başlamadan kapanır ve eski oturum
sonucu okuyamaz. [Tam üç kabul ölçütü ve exact kanıt](s06-6-recovery-status-implementation-2026-09-20.md).

Exact `60ab69e6` PR ağacı ile main `8ed2f72a` ağacı aynıdır. Altı servis için
iki mimarili native kapılar, dört Server shardı, Android ve Security geçti;
bağımsız incelemede başarısız Jellyfin bootstrap'ının eski readback ile
`verified` görünmesi engellendi. S06.6 `done`, kuyruk **17/125 (%13,6)** ve S06
koordinatörü **6/6** oldu. Fiziksel kurulum kanıt yerine sayılmaz.

## Tarihsel ara teslimler ve korunan kanıtlar

### Beşinci toplu aday — olay, transfer, Seerr ve ortak medya eylemi

- Home Assistant komut geçmişi artık append zincirindeki `pending → final`
  snapshot'larını kaynak ve aktör yetkisine özel zincir/cursor ile sıralıyor.
  Başka kullanıcı veya kaynağın global sıra konumu görünmüyor; restartta okuma
  provider çağrısı veya komut replay'i yapmıyor.
- Bounded indirme başlangıç, tamamlanma ve kesilme makbuzları HMAC doğrulamalı
  kalıcı depoya yazılıyor. Restart yarım işi `interrupted` yapıyor; aynı işlem
  kimliği provider açılmadan replay/çatışma olarak ayrılıyor. Salt okunur tekil
  ve sınırlı geçmiş API'leri Swagger sözleşmesine eklendi.
- S08.10 ürün blob sağlayıcısı yetkili raw upload'u JSON yolundan ayırıyor;
  byte'ları AES-GCM ile saklıyor, exact user/resource/ACL/provider revision,
  digest, boyut, media type ve idempotency makbuzunu atomik bağlıyor. Restart,
  replacement, kaynak silme, saat geri gidişi ve SQLite tamper kapalı testlerde.
- Android kaynak paneli ürün descriptor'ını kapalı sözleşmeyle okuyor; indirmeyi
  sabit revision yerine güncel digest/type/length/revision ile bağlıyor. Yalnız
  write yetkili satır, yol taşımayan 256 KiB picker'dan ilk yükleme/değiştirme
  yapabiliyor; hesap, ev, pencere veya ACL değişimindeki geç sonuç bırakılıyor.
- Seerr 3.4.1 için amd64/arm64 native workflow; sahiplikli `/app/config`, özel
  ağ, sabit create/start, `initialized=false` public readback, kaynak sınırları
  ve restart sonrası aynı taze durum kanıtını üretiyor. `installAvailable=false`
  korunuyor.
- Media ana ekranındaki arama eylemi EN/TR ekran okuyucu adı, görünür klavye
  odağı ve Tab+Enter akışıyla 600/1280 genişlik ve 2× metin matrisine alındı.

Yerel kanıt: komut geçmişi paketi **71**, bounded transfer ve ilişkili Core
paketleri **174**, Seerr/native araç paketleri **53 + 295**, medya widget paketi
**8/8** geçti; security policy, compileall, gitleaks ve hedefli analiz temiz.
Exact PR/main CI ve Seerr gerçek native makbuzları tamamlandı. Medya-özel
protokoller ile fiziksel SAF açık olduğundan S08.10 ve B5.1 kapanmadı; S06.6'nın
kabulüyle güncel sayaçlar **17/125 (%13,6)** ve **0/63 (%0,0)** oldu.

### F62 RDP — bounded Client yazılım dilimi

Core ve Proxmox'tan bağımsız kişisel RDP profilleri; hedef/gateway ayrımı,
Windows domain, şifreli kimlik bilgisi ve sertifika pini, açık bağlantı/yeniden
bağlantı, tablet/DeX pointer-klavye-resize yüzeyi olarak hazırlandı. Üretim
varsayılanı native motor yokken bağlantı denemez. Receipted AAR artık gerçek
APK derlemesine koşullu bağlanır; production MethodChannel motoru SPKI/TLS/NLA,
BGRA framebuffer, pointer/klavye/IME ve DeX resize akışını aynı sahipli oturuma
taşır. Ses/dosya ve RD Gateway yeteneği güvenli biçimde kapalıdır. İzole gerçek
Windows hostu ve fiziksel Huawei tablet/DeX kabulü açık olduğundan F62 kabulü ve
**17/125 · 0/63** sayaçları değişmedi. FreeRDP 3.31.1 kaynak/araç zinciri/ABI
kilidi, GitHub-hosted AAR+APK makbuzu ve varsayılan kapalı kanal sözleşmesi ayrı
yazılım kapısı olarak hazırlandı. Ayrıntı:
[bounded RDP Client dilimi](rdp-client-flow-2026-09-11.md) ve
[FreeRDP native motor kapısı](f62-freerdp-native-engine-acceptance-2026-09-20.md).
### Bağımsız F61 VNC Client temeli — yerel dal

`codex/vnc-client-foundation-main` dalında REMOTE.COMMON VNC profili için RFB 3.8,
TLS/SPKI sabitleme, düz VNC varsayılan reddi, tek kullanımlık ve bellekte
sıfırlanan parola taşıması, tek denemelik yaşam döngüsü ve EN/TR tablet/DeX
hazırlık paneli eklendi. Varsayılan `UnsupportedVncEngine` DNS/socket açmadan
yerel motorun paketlenmediğini bildirir. Bu dilim F61'i kapatmaz; native motor,
gerçek sunucu E2E, framebuffer/girdi, CI ve fiziksel Huawei/DeX kabulü açıktır.
[Kapsam ve kanıt](vnc-client-foundation-2026-09-10.md).


### Tamamlanan toplu kilometre taşı — PR64

Ara commitlerde yalnız ilgili testler çalıştırılıyor; aynı teslim grubunun tam
Android, Server, E2E, güvenlik ve iki mimarili native kapıları tek exact head
üzerinde bir kez çalışıyor. [PR64](https://github.com/ersingundem/larenor/pull/64)
şu yazılım dilimlerini birlikte taşıyor:

- Seerr ve Music Assistant için kalıcı, plan-türetilmiş Core kurulum işleri;
  kullanıcı Docker girdisi yok ve `installAvailable=false` korunuyor.
- HA komutlarında actor/source/reason/correlation geçmişi ile şifreli append
  zinciri ve dış HMAC checkpoint doğrulaması.
- IP, alan adı ve IPv6 hedefli SSH/RDP/VNC profil yönetimi ile PIN korumalı,
  host-key pinli ve şifreli kimlik bilgili ilk SSH terminali.
- Home Assistant service-check için varsayılan ret, exact origin/IP izinleri,
  DNS/peer doğrulaması ve şifreli denetim kaydı.

Yerel toplu doğrulamada seçili Server paketleri; 226 birleşik
Keenetic/uzak-erisim/Ayarlar tablet testi; 49 SSH testi; 543 bileşen internet
izni testi; güvenlik politikası ve kuyruk doğrulaması geçti. İlk tam CI denemesi
Music Assistant'ın yeni worker capability değerini beklemeyen dört tarihsel
fixture buldu; fixture'lar güncellendi ve ilgili 44 test geçti. Yeni exact head
için 15/15 zorunlu CI kontrolü geçti ve PR64 ana dala alındı. Bu dilimler
F13/F20/F63 veya S06.5'in bütün
kabul ölçütlerini tek başına kapatmadığı için kanıt sayaçları henüz artırılmadı.

### Tamamlanan ikinci toplu kilometre taşı — PR65

Her commit `tool/commit_with_progress.py` ile kuyruktaki kanıtlı durumu okur ve
`Larenor-Queue-Progress` ile `Larenor-Feature-Progress` trailerlarını ekler.
Kısmi geliştirme yüzdeleri yükseltmez. Şu anki kanıtlı değerler **14/125
(%11,2)** ve **0/63 (%0,0)**.

[PR65](https://github.com/ersingundem/larenor/pull/65) şu parçaları tek kabul
noktasında birleştirdi:

- Music Assistant'ın doğrulanmış kurulumundan şifreli authenticated readback,
  tekil HA/Jellyfin keşfi ve revision bağlama.
- Spotify, Apple Music ve YouTube Music için şifreli ve idempotent provider
  kurulum niyetleri; beklenmeyen URL/alan/akış durumunda kapalı davranış.
- Paylaşılan SSH kimliği ve host pinini kullanan, 200 öğe ve 64 MiB sınırına
  sahip tablet SFTP tarayıcısı ile açık indirme/yükleme.
- Actor/source/reason/result ve bütünlük/checkpoint durumunu gösteren salt
  okunur tablet HA etkinlik ekranı.

Yerel birleşim kapısında seçili Music Assistant/provider Server testleri ve
**298 birleşik SFTP/SSH/Core HA Flutter testi** geçti. Exact PR head üzerinde
Android analiz/test, debug APK, API 35 emülatör E2E, Server, Security ve iki
mimarili Jellyfin/Arr/qBittorrent karakterizasyonu dahil **15/15 zorunlu
kontrol** geçti. Gerçek sağlayıcı hesabı, gerçek SFTP hostu ve fiziksel tablet
kabulü ayrı kaldı.

### Hazırlanan üçüncü toplu kilometre taşı

- Music Assistant provider form/OAuth worker'ı yalnız şifreli Unix IPC ile
  çalışıyor; exact instance/domain/loaded readback olmadan hazır saymıyor.
- HomePod/AirPlay dahil doğrulanmış player keşfi; açık play/pause/stop/skip,
  ses/mute ve queue add/replace/clear niyetleri revision, idempotency,
  deadline ve authenticated readback ile kapalı davranıyor.
- Kişisel SSH tarafında loopback tünel, dört PTY terminal sekmesi, Türkçe UTF-8,
  SFTP, keyboard-interactive MFA ve tek açık jump host; kopuşta otomatik komut,
  retry veya replay yok.
- F20 Client checkpoint'i Android güvenli depoda Core/ev kapsamıyla açıkça
  pin/rotate/export ediliyor; gerçek loopback Core restore/rollback/tamper ve
  geç yanıt/401/yetki kaybı E2E'si var.
- Her PR commitindeki iki yüzde trailerı artık CI'da doğrulanıyor. Günlük
  artifact işi eski tamamlanmış debug APK'lardan en yeni üçünü koruyor; ilk
  canlı tur **5 artifact / 651.810.797 bayt** sildi, belirsiz sonuç üretmedi.

Bu birleşimde ilgili Server **39**, Flutter **374** ve araç/güvenlik **257**
testi geçti. Commit ilerleme kapısı bu kayıt dahil mevcut **23/23** commit
mesajını doğruluyor.
Gerçek HomePod/sağlayıcı, iki hostlu SSH fixture, fiziksel Huawei/DeX ve GitHub
PR/CI kabulü açık olduğundan sayaçlar **14/125 (%11,2)** ve **0/63 (%0,0)**
olarak korunuyor. S08.9 Keenetic/Proxmox ve S08.10 bounded transfer pilotları
bir sonraki toplu paket için paralel yürütülüyor.

### S08.9 merkezi altyapı kabulü — tamamlandı

Sabit `a052362` tabanında Proxmox ve Keenetic için ortak kabul matrisi eklendi.
Eski binding veya komut önizlemesi endpoint/credential, kaynak, ACL, binding,
servis revision ya da oturum değişikliğinden sonra kullanılamıyor; geç veya
belirsiz sonuç başarıya yükseltilmiyor ve yeniden yürütülmüyor. Sentetik odaklı
Server kapısında **103 test** geçti.

Core-backed Proxmox/Keenetic ayrıntı, dashboard ve komut yüzeyleri aynı bağlantı
kanıtı sözlüğünü kullanıyor. Komut makbuzu yalnız Core erişilebilirliğini
gösteriyor; timestamp'li cihaz okuması olmadan doğrulanmış veri iddiası
oluşturmuyor. İlk **37 Flutter** kapısından sonra `f8f23239`, `a00dc041` ve
`c70417ab` inceleme düzeltmeleri; kayıtlı bağlantıyı erişilebilir kanıt saymama,
child authority/lifecycle düşüşünde istek başlatmama, API değişiminde preview
sahipliğini koruma, permission-denied eşlemesi ve exact HTTP hata sözleşmesini
kapattı. Son S08.9 odaklı kapısı **43 Flutter testiyle** geçti. 600/1280
genişlik, 2× metin, 48 dp ve klavye akışları doğrulandı; hedefli analiz temiz.
Direct credential/cache fallback eklenmedi. Bağımsız incelemede bulunan bütün
P1/P2 açıkları kapandı; PR136 ve exact `addead67` main Android, Server Container
ve Security kapıları geçti. S08.9'un test/review/ci yazılım kabulü tamamlandı.
Gerçek LAN/servis kabulü `MANUAL.SERVICES`, fiziksel Huawei/DeX kabulü
`MANUAL.TABLET` altında ayrı izlenir. Kuyruk sayacı **15/125 (%12,0)** oldu;
seçili özellik sayacı **0/63** kaldı.
[Kabul taslağı ve açık kanıtlar](s08-9-infrastructure-acceptance-2026-09-11.md).

### Tamamlanan Seerr + S08.9 + imzalı beta/Core birleşimi

Exact yerel aday `d3a22ea8`; ana dal tabanı `a052362`'dir. Seerr zinciri
`ada25a16`, `21c70dc4`, `e6debec2` ve inceleme düzeltmesi `f57dc316` ile aynı
kanıtlı bağlantıda Arr wiring, initialized readback, transaction içi son yetki
kapısı, partial makbuz koruması ve tablet faz görünümünü birleştirir. S08.9
kaynağı `758583bb`/`78eeb405`; son review-fix kanıtları `f8f23239`,
`a00dc041`, `c70417ab`'dır. İmzalı beta/Core yayın zinciri `17f4c18f`, recovery
ve APK bütünlük düzeltmesi `3c19f5bd` ile temsil edilir.

İlk birleşik yerel kapıda **183 Server**, **113 Flutter** ve **78 araç/politika
testi** geçti. Sonraki dar düzeltme tekrarları Seerr için **82 Server / 26
Flutter**, beta/Core yayın ve bütünlük sınırı için **92 Server / 18 araç testi**
olarak geçti. Son receipt-coherence düzeltmesi `d3a22ea8` üzerinde ilgili
**90 Server / 26 Flutter** kapısını geçti. Bu sayılar aynı adayın yerel
kanıtıydı. Son CI politika düzeltmesi `bb8263a8` ile tamamlandı; PR136 bütün
zorunlu kontroller geçince `addead67` olarak ana dala alındı. Main Android E2E
kapanış düzeltmesiyle 17/17 testi takılmadan bitirdi ve imzalı beta
`100000520` yayımlandı. S08.9 `done` oldu; S06.5 daha geniş medya/native kabulü
nedeniyle açık kalır. İlerleme **15/125 (%12,0)** ve **0/63 (%0,0)**'dır.

### Hazırlanan dördüncü toplu kilometre taşı

- Her PR commitinin kuyruk ve seçili özellik yüzdesi GitHub Actions özetinde
  commit hash'iyle ayrı satırda gösteriliyor. Bu kayıt öncesindeki **30/30 commit**
  `14/125 (%11,2)` ve `0/63 (%0,0)` trailerlarıyla doğrulandı.
- Music Assistant 2.10.4 ilk kurulumunda Core iç yöneticiyi oluşturuyor, kısa
  kurulum anahtarını uzun ömürlü entegrasyon anahtarıyla değiştiriyor,
  onboarding'i tamamlıyor ve aynı sunucu kimliğini tekrar okuyor. Sırlar yalnız
  UID-korumalı Unix IPC ve retained worker içinde kalıyor.
- Proxmox pilotunda yönetici preview/confirm ve üye salt okunur Core ekranı;
  kaynak seçen Core-backed dashboard widget'ı, node/QEMU-LXC/storage özeti ve
  stale/denied/offline ayrımı var. Core yolunda Direct fallback yok.
- Keenetic pilotu authenticated Core kaynağından internet durumu, public IP,
  uptime, indirme/yükleme, CPU/RAM ve çevrimiçi cihaz özetini tablet/DeX paneli
  ve kaynak/revision bağlı dashboard kartında gösteriyor. Yönlendirici ayarı
  değiştirmiyor ve Direct kimlik bilgisi/cache yoluna dönmüyor.
- S08.10 bounded indirme pilotu trace, sıra, final frame, uzunluk, SHA-256,
  içerik türü ve servis revision doğrulanmadan Android SAF'e veri yayımlamıyor.
  İptal, timeout, oturum/lifecycle ve ACL değişiminde akış kapanıyor; otomatik
  retry, range veya resume yok.

Birleşim sonrası ilgili **228 Server** ve **100 Flutter** testi geçti; security
policy, Python compileall, kuyruk ve commit ilerleme kapıları temiz. Flutter
generated kaynakları birleşik testten önce yeniden üretildi. Uzak CI,
gerçek Proxmox/Keenetic/Music Assistant, Android SAF, Huawei MatePad ve Samsung
DeX fiziksel kabulü açık. S08.9, S08.10, S06.5 ve seçili özelliklerin bütün
kriterleri kapanmadığı için sayaçlar **14/125 (%11,2)** ve **0/63 (%0,0)**
olarak korunuyor.

| Adım | Durum | Sonraki somut çıktı |
| --- | --- | --- |
| S08.5 — restore, logout ve journal hedef sınırı | **Kabul edildi**, exact `960691c` / APK108 | [Kabul ve korunan geçmiş](restore-people-acceptance-108-2026-09-08.md) |
| S08.6 — kişi, oda, kaynak ve izin yönetimi | **Kabul edildi**, aynı yayın | Merkezi HA akışının yetki temeli hazır |
| S08.7 — merkezi Home Assistant adaptörü | **Kabul edildi**; typed switch, kalıcı komut/makbuz, Direct→Core ve kapalı salt okunur standart/özel domain projeksiyonu PR17 tam CI ile ana dala alındı | Registry/servis keşfi ve domain'e özel typed komutlar sonraki HA dilimi |
| B5.1 — ortak tablet tasarımı | **Kabul edildi**; final birleşik önizleme 240/240 PASS, PR #259 exact CI ve API 35 E2E yeşil, main `ee25ae45` | Fiziksel Huawei/DeX/klavye/TalkBack ve canlı servis matrisi MANUAL |
| B5.2 — kişisel profil ve hassas oturum | **Kabul edildi**; 44/44 odaklı PASS, exact conflict/readback ve kapalı secret modeli, PR #271 CI yeşil, main `e313328f` | Fiziksel RDP/VNC/SSH ve cihaz matrisi MANUAL |
| S06.3d — kalıcı depolama | **Kabul edildi**; Native18 exact `6a054ea`, amd64+arm64 makbuzları doğrulandı | S06.3f ile birleşik kaynak kapısı kapandı |
| S06.3f — kaynak kabulü | **Kabul edildi**; exact `4021391`, iki mimarili native makbuz, 4.065 Server ve tam Android/Server CI yeşil | S06.4 dar kurulum yürütme kapısı |
| S06.4 — dar kurulum yürütme kapısı | **Kabul edildi**; PR16 `bf6f860`, PR18 `75af015`, PR19 `9ce3c5a` ve PR20 `2b9166b` tam CI kapıları yeşil | S06.5 özel bootstrap ve otomatik servis eşleştirme |
| S06.5 — özel bootstrap ve otomatik eşleştirme | **Kabul edildi**; exact `f78f138c` ile aynı ağaca sahip main `b38c8ab9`. Jellyfin/qBittorrent/Arr zincirlerine ek olarak Seerr 3.4.1 ve Music Assistant 2.10.4 private bootstrap, authenticated readback ve restart akışları amd64/arm64 geçti | S06.6 doğrulanmış sonuç, iptal ve kurtarma; birleşik dağıtım S07 |
| S06.6 — doğrulanmış sonuç, iptal ve kurtarma | **Kabul edildi**; exact PR `60ab69e6` ile aynı ağaca sahip main `8ed2f72a`. Altı servis sonucu, restart/iptal/belirsiz etki ve yetki kaybı fail-closed doğrulandı | Birleşik dağıtım S07; fiziksel ev/alıcı kabulü MANUAL |

S06.5'in ilk iki TDD parçası, yalnız tamamlanmış Jellyfin kurulumundan
yöneticiye bağlı bootstrap niyeti üretir ve public API'de sır, hedef adres veya
Docker yetkisi kabul etmez. Ayrı adaptör resmi startup sırasını tek, önceden
doğrulanmış bağlantıda; bounded başlık/gövde ve ortak total deadline ile
yürütür. Redirect/retry yoktur; kısmi veya belirsiz yazma sonucu sabit ve
secret-free hata durumuyla üst koordinatöre bırakılır. Odaklı 30 test ve ilgili
81 test geçti. Exact `9882c7c` kaynak, sabit apksig 9.1.0 ve gerçek JDK 17 ile
tam yerel Server paketinde **4.381 PASS / 13 macOS skip** verdi; security policy
ve derleme kontrolü de temiz. GitHub CI henüz kabul edilmedi; gerçek
container/LAN işlemi yapılmadı.
[Uygulama ve açık sınırlar](media-service-bootstrap-implementation-2026-09-09.md).

Sonraki `e04a06a` → `832b44a` TDD dilimi, exact journal container ID ve
yeniden doğrulanmış stack/binding ile çalışan container'ın tek internal control
network IPv4/prefix/gateway gözlemini birleştiriyor. Yalnız RFC1918 subnet ve
sabit Jellyfin TCP/8096 listener'ı numeric bağlantı üretebilir; DNS, proxy,
alternatif adres ve retry yoktur. **27 yeni / 86 ilgili test** geçti. Bu bağlantı
henüz gerçek ağa açılmadı. `42128c2` → `5a1b1b0`, ardından `89687d1` ile
tamamlanan üçüncü dilim bu kanıtı başarılı `start_container` journal receipt'i,
dört retained-authority kapısı, startup öncesi/sonrası taze container gözlemi
ve tek ortak deadline içinde birleştiriyor. Bağlantı erişilemezliği endpoint
değişiminden ayrı raporlanıyor; beş resmi adım doğrulanmadan başarı üretilmiyor.
**14 yeni / 100 ilgili test** ile security policy, compileall ve diff kontrolü
geçti. IPC/supervisor dispatch ve kalıcı bootstrap durum geçişi henüz bağlı
değil; bu kaynak gerçek Docker/Jellyfin ağına dokunmadı.

`b931fdd` → `2e75cd3` TDD dilimi public duruma secret-free `errorCode` ekledi
ve koordinatörün `queued → running → credentials_configured` geçişini kalıcı
hale getirdi. Kesilmiş `running` kayıt restart sonrasında yeniden denenmiyor;
`bootstrap_interrupted` ile insan incelemesine ayrılıyor. Yetki kaybı backend
çağrısından önce duruyor; kısmi/belirsiz etki `needs_attention`, kesin bağlantı
erişilemezliği `failed` oluyor. **18 odaklı / 90 ilgili test** geçti. Production
Core backend'i bu ara committe kapalıydı; gerçek servis işlemi yapılmadı.

`e9a71a3` → `ae96651` ve `26aca71` → `d8d8276` TDD dilimleri aynı
UID-korumalı installation Unix socket'e private bootstrap operasyonunu ekledi.
Core yalnız bu socket yapılandırılmışsa koordinatörü backend'e bağlar. Exact
job/plan/private sözleşme dışındaki giriş worker'a ulaşmaz; kısmi sonuç yalnız
sabit adım, hata kodu ve belirsizlik taşır. Runtime kurulum ve bootstrap için
aynı journal/binding'i kullanır; supervisor iç gate'leri ve Docker bağlantılarını
aynı retained daemon lease'i/native thread içinde doğrular. Sentetik gerçek
Unix-soket Core→IPC→worker yolculuğu dahil **11 yeni / 149 ilgili test** geçti;
bir Linux-only test macOS'ta skip edildi. Gerçek Docker/Jellyfin etkisi yapılmadı.

`dcf6b17` yaşam döngüsü düzeltmesi, kalıcı bootstrap kuyruğunu Server açılışında
otomatik dispatcher'a bağladı. Kapanış devam eden UID-korumalı IPC çağrısının
şifreli makbuz yazımını bekliyor; beklenmeyen yürütücü ayrıntıları yerine yalnız
sabit hata kodu loglanıyor. Gerçek Unix-soket yolculuğu ve diğer dispatcher
regresyonları dahil **57 ilgili test** geçti. Exact GitHub CI açık olduğundan
S06.5 ve genel sayaç değişmedi.

`7668017` → `0745d70`, `c790748` → `61be275`, `1f36ed5` / `22bae10` →
`a681d74` ve `e95e436` → `d198a72` TDD zinciri, tamamlanan startup'tan sonra
ikinci kez doğrulanmış private endpoint üzerinde Jellyfin sistem kullanıcısını
authenticate eder. Tek doğrulanmış `Larenor Core` API anahtarını yeniden kullanır;
yoksa bir kez oluşturup geri okumadan kabul etmez. `System/Info` kimliği ve
`Library/VirtualFolders` sonucu kapalı modele alınır, geçici auth oturumu
`Sessions/Logout` ile kapatılır. API key, session token, parola ve medya yolları
UID-korumalı IPC dışında görünmez; Core sonucu AES-GCM ciphertext olarak saklar
ve public durumu yalnız `wiring_partial` yapar. İlk dilimde ilgili altı paket **110 PASS**,
değişen ve doğrudan bağlı beş modül branch coverage toplamı **%80** verdi.
[TDD kanıtı ve açık sınırlar](jellyfin-authenticated-readback-implementation-2026-09-09.md).

Native genişletmenin son `2c3f591` kaynağı, Jellyfin 10.11.11'in gerçek ilk
kullanıcı adı, iki zorunlu remote-access alanı, internal Docker ağındaki boş
gateway gözlemi, null alanları atılan `ApiKey` wire biçimi ve wizard sonrası
sağlık durumuyla eşleştirildi. **655 ilgili test** geçti. Exact
[CI 34389549143](https://github.com/ersingundem/larenor/actions/runs/34389549143)
arm64 ve amd64 üzerinde bootstrap/readback/logout, ilk sağlık, restart sağlık,
kimlik ve kalıcı veri kontrollerini tamamladı; public makbuzda sır bulunmuyor.

Sonraki `1f998d3` → `a62b904`, `33e6bf5` → `a0d1420` TDD dilimi sabit
`Larenor Movies` ve `Larenor Shows` kütüphanelerini üçüncü doğrulanmış private
endpoint üzerinde idempotent oluşturup yeniden okur. İlgisiz kayıtlar korunur;
ad/yol/tür çakışması ve kısmi yazma silme veya otomatik retry üretmez. Runtime,
IPC, public hata modeli ve secret-free native aşama tanıları bağlandı;
İlk sözleşmede **306 ilgili test** geçti. Native CI `34394429050`, eksik
`/media/movies` yolunu beklendiği gibi `bootstrap_wiring_create_failed` ile
kapattı. `7ac61db` bunun üzerine sekizinci journal-bound medya hacmini, sabit
dizin hazırlığını ve Jellyfin'in salt okunur `/media` bağını ekledi; genişleyen
hacim/Jellyfin paketi **513 PASS** verdi. `33bb2d2` ayrıca Jellyfin'in geçerli
kütüphane sıralarını bağımsız kabul edip yanlış/ekstra kayıtları reddeden
matcher ve kapalı sonuç tanıları ekledi; paket **514 PASS** oldu. Exact
[CI 34398527312](https://github.com/ersingundem/larenor/actions/runs/34398527312)
AMD64 ve ARM64 üzerinde geçti. İndirilen iki makbuz merge kaynağı `73fbd0a`
için repo doğrulayıcısıyla yeniden geçti. Tam Server koleksiyonunda test
assertion hatası olmadı; yerel ortamda sabit `LARENOR_TEST_APKSIG_JAR` olmadığı
için dört release-verifier crypto fixture'ı kurulamadı. İki mimarili native kabul
tamamlandı; diğer medya servisleri açık olduğu için S06.5 sayacı değişmedi.
[TDD kanıtı ve açık kabul sınırı](jellyfin-managed-libraries-implementation-2026-09-09.md).

qBittorrent dilimi, LinuxServer qBittorrent 5.2.3 için yalnız Larenor'un
yönettiği yolları ve güvenlik ayarlarını üreten deterministik config sözleşmesi
ekledi. Core'un özel Bearer akışı önce exact `v5.2.3` kimliğini, ardından API
anahtarını, portları, indirme yollarını, WebUI güvenlik bayraklarını ve sabit
`movies`/`tv` kategorilerini doğruluyor. Eksik yönetilen kategoriler eklenebiliyor;
yabancı veya çakışan durum değiştirilmiyor ve yazma sonrası bağlantı kaybı
belirsiz etki olarak raporlanıyor. **104 qBittorrent testi**, ortak HTTP
çerçeveleme/Jellyfin paketleriyle **149 test** ve yerel gitleaks taraması geçti.
Container hacim bağları ile amd64/arm64 gerçek qBittorrent kanıtı açık olduğu
için kurulum yeteneği kapalı ve kuyruk kabul sayacı değişmedi.
[Uygulama ve açık sınırlar](qbittorrent-owned-bootstrap-implementation-2026-09-10.md).

Takip eden TDD dilimi config bytes üretimini yalnız güncel `VolumeCreateJournal`
kaydından yeniden bağlanan qBittorrent `/config` appdata kaynağına bağladı.
Revision, resource/operation, journal/nonce, volume adı, child plan, portlar,
servis ve hedef eşleşmeden config üretilemiyor; işlem journal'ı değiştirmiyor.
**15 yeni / 294 ilgili test**, compileall, diff ve gitleaks kontrolü geçti.
Bu yalnız private bellek içi sözleşmedir; atomik volume yazma ve native
container kanıtı hâlâ açıktır.
[Uygulama ve açık sınırlar](qbittorrent-config-volume-binding-implementation-2026-09-10.md).

Aynı dalın ikinci parçası tek yönetilen library volume'ünü qBittorrent,
Sonarr ve Radarr için `/data` yazılabilir; Jellyfin için `/media` salt okunur
olarak tüketilecek sabit bir plana bağladı. Seerr ve Music Assistant bu medya
hacmini almıyor. **19 yeni / 315 ilgili test** geçti; bu öneri de henüz mount
veya kurulum yetkisi vermiyor.

Sonraki helper dilimi, config'i yalnız stdin'den kabul edip tek sabit
`/volume/qBittorrent/qBittorrent.conf` hedefine kuruyor. Exact allowlist,
`O_NOFOLLOW`, özel sahiplik/izinler, üzerine yazmayan atomik hard-link yayını,
dosya/dizin kimliği geri okuması ve yarım etkiyi koruyan kapalı hata politikası
uygulandı. **16 yeni / 136 ilgili test** geçti. Worker/Docker stdin etkisi ve
iki mimarili gerçek qBittorrent kabulü açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](qbittorrent-config-helper-implementation-2026-09-10.md).

Bir sonraki private worker dilimi Docker API 1.47 sürümünü, Unix socket
kimliğini ve peer UID'yi aynı attach bağlantısında doğrulayıp config'i container
metadata'sına koymadan bounded stdin ile iletiyor. Yetki private byte öncesinde
yeniden sınanıyor; non-TTY stdout/stderr frame'leri ayrı ve sınırlı okunuyor.
Journal-bound effect sabit networksüz/RW-volume helper gövdesini
create/start/stream/wait/remove sırasıyla çalıştırıyor, exact digest/state
sonucunu ve kaynağı etkiden sonra tekrar doğruluyor. **37 yeni / 274 ilgili
test** geçti. Supervisor/IPC state bağı ve iki mimarili native kabul açık.
[Uygulama ve açık sınırlar](qbittorrent-config-effect-implementation-2026-09-10.md).

Takip eden runtime dilimi stack ve volume planını worker içinde yeniden türetip yalnız güncel qBittorrent `/config` intent'ini seçiyor. Pinned helper ve platform ile kurulan effect, installation supervisor'ın aynı native thread/retained-daemon kapısında etki öncesi, iç gate'lerde ve etki sonrası doğrulanıyor. Bilinmeyen adapter hataları ayrıntı sızdırmadan belirsiz etki oluyor. **12 yeni; runtime ve supervisor paketinde 70 PASS / 1 mevcut macOS skip; geniş pakette 343 PASS / 2 mevcut macOS skip; tam Server koleksiyonunda 4.736 test / exit 0**. Kalıcı şifreli job, IPC operasyonu, create/start önkoşulu ve native kabul açık.
[Uygulama ve açık sınırlar](qbittorrent-runtime-binding-implementation-2026-09-10.md).

`0983c28` TDD dilimi qBittorrent private config isteğini ayrı mutating worker
socket'ine bağladı. Core ve worker packaged stack'i ayrı ayrı doğruluyor; iş
kimliği runtime sınırına kadar taşınıyor; credential, API key, salt ve config
bytes public modele veya makbuza girmiyor. Etki sonrası Core yetkisi kaybolursa
sonuç belirsiz etki oluyor. **14 yeni test; 418 ilgili testte 417 PASS / 1 mevcut
macOS skip**, compileall, queue, diff ve gitleaks kontrolü geçti. Kalıcı şifreli
qBittorrent job, create/start sırası ve iki mimarili native kabul açık olduğu
için sayaç değişmedi.
[Uygulama ve açık sınırlar](qbittorrent-installation-ipc-implementation-2026-09-10.md).

`9bf5f40` TDD dilimi Core'un ürettiği qBittorrent credential, API key ve salt'ı
satır kimliği/durum/kaynak bağlamlı AES-GCM kayıt içinde tutan kalıcı işi ekledi.
Admin API oluşturma, sınırlı listeleme, okuma ve revision-bound iptal sunuyor;
dispatcher gerçek UID-korumalı IPC'yi otomatik çağırıyor ve kapanışta devam eden
makbuzu bekliyor. Restart sırasında `running` kalan iş tekrar edilmiyor; etki
sonrası iptal, yetki kaybı veya bilinmeyen worker kopması açıkça
`needs_attention` oluyor. **23 yeni ve 263 ilgili test PASS**; sabit apksig/JDK
ile dört gerçek APK doğrulama testi de geçti. Create/start sırası, iki mimarili
native qBittorrent ve otomatik servis eşleştirmesi açık olduğu için sayaç
değişmedi ve `installAvailable=false` kaldı.
Exact `420ba57` kaynağının Server, Android analyze/debug/E2E, güvenlik ve iki
mimarili karakterizasyon kapıları geçerek PR37 üzerinden ana dala birleşti.
[Uygulama ve açık sınırlar](qbittorrent-configuration-jobs-implementation-2026-09-10.md).

`da879f3` TDD dilimi qBittorrent işini tek kapalı worker operasyonunda önce
owned config'i kurup doğrulamaya, ardından aynı retained-daemon/native-thread
otoritesiyle sabit container binding'ini üretip create/start etmeye bağladı.
Binding yalnız owned `/config` ve ortak yazılabilir `/data` volume'lerini kabul
ediyor; published port yok. Birleşik şifreli makbuz public durumda yalnız
`container_started` gösteriyor; önceki config-only kayıtlar okunabilir kalıp
container başarısı iddia etmiyor. **229 ilgili testte 228 PASS / 1 mevcut macOS
skip**, compileall, diff ve queue doğrulaması temiz. Exact CI ile gerçek
amd64/arm64 servis/readback/restart kanıtı açık olduğundan sayaç ve
`installAvailable=false` değişmedi.
Exact `729eb1e` kaynağının Server, Android analyze/debug/E2E, güvenlik ve iki
mimarili karakterizasyon kapıları geçerek PR38 üzerinden ana dala birleşti.
[Uygulama ve açık sınırlar](qbittorrent-configured-container-implementation-2026-09-10.md).

`2934815` qBittorrent private endpoint dilimi yalnız exact running container,
journal binding'i ve tek Larenor control-network gözleminden RFC1918 numeric
TCP/8080 bağlantısı üretiyor; DNS, proxy, alternatif hedef veya public port yok.
Worker-private bootstrap executor önce sabit `movies`/`tv` kategorilerini
idempotent doğruluyor, sonra taze kanalda pinned sürüm, API key ve owned ayarları
geri okuyor. Altı retained-authority kapısı ve her etkiden önce/sonra endpoint
drift kontrolü var; olası yazma sonrası hata belirsiz etki. **354 ilgili testte
353 PASS / 1 mevcut macOS skip**, compileall, security policy ve gitleaks temiz.
Exact PR39 head `98a7a1c` Server, Android analyze/debug/API35 E2E, güvenlik ve
iki mimarili karakterizasyon kapılarından geçip `ec977b2` ile ana dala
birleşti. Core IPC/runtime dispatch sonraki dilimde bağlandı; native servis
kanıtı açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](qbittorrent-private-bootstrap-implementation-2026-09-10.md).

`a1e3bb6` doğrulanmış-servis dilimi yalnız ilk read-only TCP hazır olma
bağlantısını ortak deadline içinde yeniden deniyor; her denemede yetkiyi,
journal-bound container'ı ve aynı private numeric endpoint'i yeniden kanıtlıyor.
Runtime kategori ve authenticated readback'i config/create/start sonrasına
bağladı. UID IPC yalnız `qbittorrent_service_verified` makbuzunu başarı kabul
ediyor; Core bunu şifreli saklayıp public durumda `serviceState=verified`
gösteriyor. Eski config-only veya container-started kayıtlar okunuyor fakat
doğrulandı sayılmıyor. **130 odaklı test PASS / 1 mevcut macOS skip**; sabit
apksig 9.1.0 jar ve JDK 17 ile tam Server paketi **4.831 PASS / 13 platform
skip**. Security policy, compileall, queue, diff ve gitleaks temiz.
PR41'in gerçek servis koşuları Docker'ın çalışan container endpoint projeksiyonu,
qBittorrent'in exact `qbt_` API-key biçimi ve WebUI UPnP'den bağımsız peer-port
yönlendirme ayarını ortaya çıkardı. Kapalı sözleşmeler bu gerçek davranışlara
göre düzeltildi; **289 ilgili yerel test PASS**. Exact PR head `f00a869` için
[CI 34437420807](https://github.com/ersingundem/larenor/actions/runs/34437420807)
amd64 ve arm64 üzerinde config, start, Bearer auth, iki kalıcı kategori, restart
ve ikinci readback adımlarının tamamını geçti. İndirilen iki makbuz exact merge
kaynağı `8cf7257` ile repo doğrulayıcısında yeniden PASS oldu. Diğer medya
servislerinin otomatik eşleştirmesi açık olduğu için sayaç ve
`installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](qbittorrent-service-verification-implementation-2026-09-10.md).

`9df82dd` ile başlayan Arr dilimi, sabitlenmiş Sonarr `4.0.19.2979` ve Radarr
`6.3.0.10514` kaynaklarındaki 32 karakterlik API-key ve `config.xml` başlangıç
davranışını kapalı bir üreticiye bağladı. Yalnız `sonarr`/`radarr`, sabit port,
örnek adı ve güvenlik ilkesi kabul ediliyor; secret ve dosya baytları `repr`
çıktısına girmiyor. Exact karşılaştırma ek veya değiştirilmiş XML'i ve servisler
arası yeniden kullanımı reddediyor. **36 yeni / 218 ilgili test**, compileall,
security policy ve diff kontrolü PASS. Henüz dosya sistemi/Docker etkisi olmadığı
için sayaç ve `installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](arr-owned-config-implementation-2026-09-10.md).

`0643801` helper dilimi, Sonarr ve Radarr exact XML'ini yalnız ayrı kapalı
komutlarla `/volume/config.xml` hedefine yazıyor. Byte'lar sadece bounded
stdin'den alınır; servis/yol/izin seçimi yoktur. UID/GID `1000:1000`, hacim
`0750`, dosya `0600`, `O_NOFOLLOW`/`O_EXCL`, tek-link denetimi, atomik
no-overwrite yayın, `fsync` ve exact geri okuma birlikte uygulanır. Aynı içerik
idempotent kabul edilir; symlink, hardlink, yanlış mod, yabancı dosya veya kalan
geçici dosya korunup çakışma olur. Helper paketinde **58 PASS**, owned config ile
**94 ilgili PASS**; compileall, security policy, queue ve diff temiz. Bu kaynak
henüz Docker effect veya gerçek servis başlangıcı yapmadığı için sayaç ve
`installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](arr-config-helper-implementation-2026-09-10.md).

`25b7850` saf binding dilimi, Sonarr/Radarr config üretimini yalnız güncel
`VolumeCreateJournal` intent'inden yeniden türetilen ilgili `/config` appdata
kaynağına bağladı. Resource/operation/journal/nonce/revision, plan digest'leri,
installation, volume, servis, kullanıcı, mount ve sabit stack ayarlarının tamamı
eşleşmeden config üretilemiyor. Bütün binding alanları ve API key yeniden
doğrulanıyor; public API servis/yol/port/stack/policy seçimi almıyor ve hiçbir
host/ağ etkisi oluşturmuyor. **44 yeni / 138 ilgili test**, compileall, security
policy, queue, diff ve Gitleaks PASS. Docker effect ve native kabul açık olduğu
için sayaç ve `installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](arr-config-binding-implementation-2026-09-10.md).

`87449f1` worker effect dilimi, journal-bound config'i sabit digest'li, ağsız,
salt okunur-root, capability'siz ve `1000:1000` helper'a bounded Engine stdin
ile iletiyor. Caller Docker gövdesi, komut, volume, yol, ağ veya container adı
seçemiyor; secret create metadata'sına ve makbuza girmiyor. Kaynak işlem
öncesi/sonrası yeniden bağlanıyor, exact digest ile servise ait durum zorunlu.
Geçersiz container kimliği cleanup yoluna girmiyor; start sonrası sapmalar
belirsiz etki oluyor. **22 yeni / 160 ilgili test**, compileall, security policy,
queue, diff ve Gitleaks PASS. Runtime/container ve native API kabulü açık olduğu
için sayaç ve `installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](arr-config-effect-implementation-2026-09-10.md).

`228687d` runtime dilimi, Arr config effect'i packaged catalog/policy ile yeniden
türetilen güncel appdata intent'ine ve installation supervisor'ın aynı retained
daemon/native thread kapısına bağladı. Sonarr/Radarr seçimi kapalı; API key exact
32 hex, internal iş kimliği 32 hex. Stale journal helper'a ulaşmıyor; Docker
transport ve private stdin aynı peer verifier'ı kullanıyor. `daff353`, değişen
backend yapıcısını qBittorrent native kabul giriş noktasında da iki config
runtime'ıyla eşledi ve çapraz sözleşme testi ekledi. **20 yeni test**; ilk tam
ilgili koşuda **251 PASS / 1 mevcut macOS skip**, düzeltme sonrası seçili yedi
pakette **148 PASS / 1 mevcut macOS skip**. Compileall, security
policy, queue, diff ve Gitleaks PASS. Kalıcı Core işi, IPC, container create/start
ve native API kabulü açık olduğu için sayaç ve `installAvailable=false`
değişmedi.
[Uygulama ve açık sınırlar](arr-config-runtime-implementation-2026-09-10.md).

`ebf98c0` IPC dilimi, strict private Arr modelini UID-korumalı installation Unix
socket'ine ekledi. Client ve server plan/model/iş/deadline/peer sınırlarını
yeniden doğruluyor; runtime sadece `configure_arr` operasyonundan çağrılıyor.
Yetki dispatch öncesi ve sonuç sonrası tekrar sınanıyor; Sonarr/Radarr makbuz
eşleşmesi üç katmanda doğrulanıyor. Status iki servisi bildiriyor fakat
`installAvailable=false`. **18 yeni test**; ilgili altı pakette **140 PASS / 1
mevcut macOS skip**. Compileall, security policy, queue, diff ve Gitleaks PASS.
Kalıcı Core işi, container zinciri ve native API kabulü açık olduğundan sayaç
değişmedi.
[Uygulama ve açık sınırlar](arr-configuration-ipc-implementation-2026-09-10.md).

`c3eacee` kalıcı iş dilimi, Sonarr ve Radarr yapılandırmalarını servis başına
tekil, yöneticiye bağlı ve AES-GCM şifreli no-retry işlere dönüştürdü. API
anahtarı yalnız Server tarafından üretiliyor; public modeller, hata ve repr
yüzeyleri sırrı taşımıyor. Yaşam döngüsü dispatcher'ı UID-korumalı worker IPC
üzerinden exact servis makbuzunu kaydediyor; kesinti ve belirsiz etkiler otomatik
tekrarlanmıyor. **5 yeni uçtan uca sözleşme testi** dahil ilgili Arr paketlerinde
**267 PASS / 1 mevcut macOS skip**. Security policy, queue, compileall, diff ve Gitleaks PASS. Container
create/start ve gerçek native API readback açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-configuration-jobs-implementation-2026-09-10.md).

`f113835` readback dilimi, Sonarr/Radarr pinned servis adı ve sürümünü
`X-Api-Key` ile sabit system/status endpoint'inden doğruluyor. Hedef, proxy,
resolver veya serbest header girdisi yok; auth, protokol, servis/sürüm sapması ve
timeout secret-free statik sonuçlara kapanıyor. **14 yeni test**, compileall,
security policy, queue ve Gitleaks PASS. Container zinciri ve iki mimarili native
kabul açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-authenticated-readback-implementation-2026-09-10.md).

`b02bdb6` endpoint dilimi ortak managed-container builder'ı Sonarr/Radarr'a
genişletti ve exact journal/container/ağ proof'undan sabit private 8989/7878
stream'i üretti. DNS, proxy, alternatif hedef ve retry yok. Arr endpoint/readback
ile mevcut Jellyfin/qBittorrent regresyonlarında **97 PASS**; security, queue ve
Gitleaks PASS. Create/start orkestrasyonu açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-private-endpoint-implementation-2026-09-10.md).

`cdeb54c`–`06242ba` zinciri, config sonrası create/start, fresh private endpoint,
authenticated readback, UID-korumalı IPC ve kalıcı Core sonucunu birleştirdi.
Public iş durumu config, container ve doğrulanmış servis sonucunu ayırıyor; çapraz
servis veya belirsiz sonuç retry edilmeden kapanıyor. `6a1270a` okunabilirlik
düzenlemesiyle deadline readback başlamadan tükenirse açılmış özel stream'in de
kapatılmasını güvenceye aldı. `8f3bfc9`, yanlışlıkla qBittorrent'a yönlenen Arr
reconcile metodunu seçili servise geri bağladı ve qBittorrent reconcile metodunu
doğru sınıfa taşıdı. `382c8a9`, eksik Arr supervisor metodunu tamamladı ve
config/create/start/readback zincirini aynı retained daemon/native thread
kanıtına bağladı; yürütme ile bootstrap yetki, timeout, kaynak ve geçersiz sonuç
hatalarını kapalı, secret-free belirsiz sonuçlara ayırdı. İlgili 13 pakette
**313 PASS / 1 mevcut macOS skip**; Ruff,
compileall, security, queue ve Gitleaks PASS. İki mimarili native
kabul açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-configured-container-implementation-2026-09-10.md).

`c16c107`–`e9ac68c` zinciri, Sonarr için `/data/shows` ve Radarr için
`/data/movies` kökünü private API üzerinden idempotent biçimde oluşturup ikinci
okumada doğruluyor. Exact mevcut kayıt değişmeden geçiyor; yabancı, ek veya
bozuk kayıt silinmeden `arr_root_folder_conflict` durumuna kapanıyor. Sonuç
bootstrap makbuzuna bağlandı; **23 odaklı / 151 ilgili PASS**, compileall,
security policy, queue ve Gitleaks yeşil. Native dizin hazırlığı, qBittorrent
download-client kaydı ve iki mimarili kabul açık olduğundan sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-root-folder-wiring-implementation-2026-09-10.md).

`7f03b85` native kabul dilimi, Sonarr ve Radarr'ı gerçek AMD64/ARM64
runner'larında ayrı dört iş olarak config/create/start/authenticated readback,
restart ve ikinci readback zincirinden geçirecek kapalı CI makbuzunu ekledi.
Ephemeral daemon/cgroup/namespace sahipliği, exact source hash'leri ve secret-free
makbuz sözleşmesi **25 odaklı / 239 ilgili PASS** ile yerelde doğrulandı; Ruff,
compileall, security policy, queue ve Gitleaks PASS. Gerçek dört native makbuz
henüz gözlenmediğinden `installAvailable=false` ve sayaç değişmedi.
[Uygulama ve açık sınırlar](arr-native-characterization-implementation-2026-09-10.md).
Native kapı PR #51 ile güncel `main` tabanında çalıştırılıyor.

`77448d0` dilimi, ortak yönetilen medya hacmindeki sabit `movies` ve `shows`
dizinlerini production Core binding kanıtına taşıdı. Journal'dan yeniden
türetilmiş tek hacim ağsız, sınırlandırılmış helper'a geçici olarak yazılabilir
bağlanıyor; yol, komut, kullanıcı ve Docker seçenekleri caller girdisi değil.
Hazırlık sonucu aynı resource/operation/journal/nonce/revision ile doğrulanıp
kök yeniden salt okunur kanıtlanmadan container binding'i üretilemiyor. **27
odaklı / 180 ilgili PASS**; Ruff, compileall, security policy, queue, diff ve
Gitleaks yeşil. Exact CI ve iki mimarili native kabul açık olduğu için sayaç ve
`installAvailable=false` değişmedi.
[Uygulama ve açık sınırlar](managed-media-directory-preparation-implementation-2026-09-10.md).

PR54 exact `7fa8350`, qBittorrent'ın config/create/start/private servis doğrulama
makbuzunu aynı preparation kimliğindeki Sonarr/Radarr işleri için zorunlu ve
fail-closed bağımlılığa dönüştürdü. PR56 exact `15fe18b`, bu şifreli private API
anahtarını Arr runtime'a taşıdı; sabit `qbittorrent:8080` download-client
test/create/readback zincirini kök klasör bootstrap'ına ekledi. Endpoint ve
yetki her sır yazımından hemen önce yeniden kanıtlanıyor. PR56'nın **15/15
zorunlu kontrolü**, Android analiz/debug/API35 E2E, tam Server, Security ve
amd64/arm64 Jellyfin/Arr/qBittorrent işleri geçti; squash merge `26978d1` ile
ana dala alındı. S06.5, Seerr ve Music Assistant açık olduğu için kapanmadı.

Seerr'ın ilk `0ffef42` → `f45ad03` ve `1cca084` → `5dc00db` TDD dilimleri,
pinned 3.4.1 API'sinde yalnız yeni `initialized:false` örneğin Jellyfin sistem
hesabıyla ilk admin oluşturmasına izin veren kapalı oturum adaptörünü ekledi.
Admin kimliği ve izin biti doğrulanıyor; yalnız dar `connect.sid` cookie kabul
ediliyor; üretilen API anahtarı geri okunup oturum kapatılıyor. Parola, cookie
ve anahtar hata veya repr yüzeyine çıkmıyor. Managed container yalnız sahipli
`/app/config` hacmi ve internal ağ alıyor; çalışan exact journal container'ından
DNS/retry olmadan RFC1918 TCP/5055 endpoint üretiliyor. **24 ilk-yönetici**, ilgili
probe/kataloglarla **236**, endpoint/binding/resource regresyonlarında **99 PASS**;
security policy ve Gitleaks temiz. PR57 exact `73ccf235` bütün zorunlu Android,
Server, Security ve iki mimarili medya kontrollerinden geçti; squash merge
`e62f407` ile ana dala alındı. Sonarr/Radarr/kütüphane/initialize eşleştirmesi
ve native Seerr kabulü henüz açık.
[TDD kanıtı ve açık sınırlar](seerr-private-bootstrap-implementation-2026-09-10.md).

Sonraki `d53c42e` → `387ed9d` ve `a560c62` → `9ab1d7e` TDD zinciri,
Seerr'ın tamamlanmış start makbuzunu aynı yönetilen ağdaki taze Jellyfin
kanıtıyla birleştiren executor'ı ve UID-korumalı worker IPC operasyonunu ekledi.
Parola gönderilmeden önce ve etkiden sonra iki konteyner ile retained daemon
yetkisi yeniden doğrulanıyor; sonuç yalnız private socket'te API anahtarı
taşıyor. **12 executor**, **7 IPC** ve mevcut kurulum/runtime/supervisor
regresyonlarıyla **160 PASS / 1 mevcut macOS skip** geçti. `341a983` →
`8dd35a7` güvenlik daraltması, worker isteğinden Jellyfin API anahtarı ve
kütüphane verisini çıkarıp yalnız parola ile kaynak bootstrap kimliği/revizyonunu
bıraktı; 6 model ve ilgili 40 test geçti. Exact `8dd35a7` üzerinde tam
Server paketi **5.243 testte geçti**. Core'un şifreli kalıcı Seerr işi henüz bağlı değil; sayaç ve `installAvailable=false` değişmedi.
[Executor ve IPC kanıtı](seerr-bootstrap-executor-implementation-2026-09-10.md).

PR58'in exact `db75479` kaynağı **15/15 zorunlu kontrolden** geçti ve squash
merge `aee92b4` ile ana dala alındı. Sonraki `fb3ecf3` → `47e3d04` TDD dilimi,
aynı doğrulanmış preparation üzerinde Jellyfin ve Seerr için ayrı kalıcı
create/start işleri üretiyor. Worker servis kimliğini plan içindeki tek
`installationId` eşleşmesinden türetiyor; request Docker/image/ağ ayrıntısı
taşımıyor. V1 kurulum ve bağlı Jellyfin bootstrap satırları v2 şemasına ciphertext
değiştirilmeden kayıpsız taşınıyor; foreign key hedefi yeniden kanıtlanıyor. **106 ilgili test**, migration/public contract ve Jellyfin bootstrap kimlik
regresyonları geçti; güncel **5.249 testlik** tam Server paketi yeniden çalışıyor.
`b8fad69a` → `8ce745cf` TDD dilimi, tamamlanmış Seerr konteynerini aynı
preparation içindeki doğrulanmış Jellyfin bootstrap kaynağına exact revizyonla
bağlayan AES-GCM şifreli kalıcı işi ekledi. Yeniden başlatma, idempotency,
kaynak/kurulum drift'i, gizli alan reddi ve sınırlı okuma kapıları yeşil.
`a8751777` → `b85a53ba` dilimi işi UID-denetimli private worker'a bağlıyor,
etki sırasında retained admin ve kaynak revizyonlarını yeniden doğruluyor,
API anahtarını yalnız şifreli kayıtta saklıyor ve belirsiz/yarım etkileri tekrar
çalıştırmadan `needs_attention` durumuna alıyor. Sonarr/Radarr/kütüphane/initialize
eşleştirmesi ve native iki mimari kabul açık; `installAvailable=false` değişmedi.
`1b944719` → `c46c5258` TDD dilimi, Seerr'ın resmî servis ayarları API'sinde
Radarr ve Sonarr bağlantısını önce test eden, yalnız doğrulanmış kalite profili
ile `/media/movies` ve `/media/tv` köklerini kabul eden, ardından create ve exact
readback yapan private adaptörü ekledi. Mevcut exact kayıt idempotent kalıyor;
yabancı kayıt veya response drift'i üzerine yazılmıyor. Adaptörün kalıcı Seerr
işine bağlanması açık. `8fddf2bd` → `6f9c9f9b` TDD dilimi, resmî
`POST /api/v1/settings/initialize` çağrısını en fazla bir etkide tutan ve aynı
`plexClientIdentifier` için authenticated public readback görmeden başarı
vermeyen adaptörü ekledi. Zaten tamamlanmış örnek idempotent kalıyor; kayıp
cevap veya şema sapması otomatik tekrarlanmayan belirsiz etki olarak kapanıyor.
Yeni 8 test ve ilgili Seerr paketinde **48 PASS**; compileall, Security ve diff
kapıları temiz. Arr ve initialize adaptörlerinin kalıcı Seerr işine bağlanması
ile native iki mimari kabul açık; `installAvailable=false` değişmedi.
[Seerr konteyner işi kanıtı](seerr-container-installation-implementation-2026-09-10.md).

S06.4 native kabul koşusu [34326112926](https://github.com/ersingundem/larenor/actions/runs/34326112926)
iki gerçek GitHub runner'ında geçti. İndirilen ARM64 ve X64 makbuzları merge
commit'i `b6e7034` için repo verifier ile tekrar doğrulandı; bu commit'in ikinci
ebeveyni PR head'i `19485ab`. Her iki makbuz da `journaled_managed_v2`, journal
sürümü 2, iki volume, bir restart, hazır imaj, kapalı bootstrap hesabı ve
`installAvailable=false` sınırını kanıtlıyor. Kaynak sınırları istek gövdesinin
yanında çalışan cgroup'da da okundu. Bu kanıt disposable CI daemon'ına aittir;
gerçek ev Docker Engine'ine yazılmadı ve ürün kurulumu açılmadı.

PR16'nın güncel `bf6f860` kaynağı için [Android Build 34332778297](https://github.com/ersingundem/larenor/actions/runs/34332778297)
5.438 Flutter, 4.225 Server, 98 Android native testi ve 17 gerçek API 35
emülatör yolculuğuyla geçti. [Security 34332777924](https://github.com/ersingundem/larenor/actions/runs/34332777924)
yeşil; [managed native 34332777927](https://github.com/ersingundem/larenor/actions/runs/34332777927)
amd64 ve arm64 üzerinde geçti. İndirilen makbuzlar merge commit'i `670614a`
ve ebeveynleri `ffdb48c` / `bf6f860` için tekrar doğrulandı.

Stacked PR18 exact `75af015`, üç mevcut journal'ı tek kapalı runtime'da açan paketli
`larenor-installation-worker` komutunu ve yalnız exact image ID, `verify_root`,
read-only NoCopy volume, networksüz geçici container kabul eden bootstrap
verifier'ı ekledi. `--check-config` journal, socket veya Engine açmaz; IPC socket'i
Docker endpoint'iyle çakışamaz ve journal içine yerleşemez. Bu yeni dilim 43
odaklı testle başladı; güncel exact kaynak yerelde **4.262 PASS / 12 platform
skip**, Linux Server CI'da **4.274 PASS** verdi. [Android Build 34341554668](https://github.com/ersingundem/larenor/actions/runs/34341554668),
[Security 34341554393](https://github.com/ersingundem/larenor/actions/runs/34341554393)
ve [managed native 34341554476](https://github.com/ersingundem/larenor/actions/runs/34341554476)
yeşil; amd64/arm64 makbuzları exact merge `adbb8476` üzerinde tekrar doğrulandı.

`cac0625` → `b6196a1` TDD dilimi, `InstallationWorkerServer` servis thread'i
hazır olmadan IPC açılışını başarılı saymıyor. Supervisor aynı thread'de tek
Docker bağlantısını, socket inode zincirini, socket-bound pidfd'yi ve daemon ile
worker proc/user/mount/network/root kimliklerini tutuyor. Her `apply` ve
`reconcile` çağrısı bu kanıtlarla çevreleniyor; daemon restart/socket değişimi,
yanlış native thread veya işlem sonrası kanıt kaybı başarı döndürmeden bütün
tutulan kaynakları kapatıyor. `5d43299` → `1e94267` düzeltmesi ayrıca image,
volume, network, bootstrap helper ve managed create/start taşıyıcılarının açtığı
her Engine bağlantısının peer PID'sini aynı tutulan canlı pidfd'ye bağlıyor.
Socket activation veya listener FD devrinde aynı inode ve UID arkasındaki farklı
daemon process'i artık kabul edilmiyor. İlgili yerel paket **272 PASS / 4 Linux
skip**;
İlk Linux Server koşusu 4.301 testin 4.300'ünü geçirip test düzeneğinin zaten
bağlı `socketpair` üzerinde ikinci kez `connect()` çağırması nedeniyle durdu;
üretim kodu etkiden önce fail-closed kapandı. `9ce3c5a` gerçek peer pidfd'sini
koruyan preconnected test sarmalayıcısını ekledi. Exact
[Android Build 34349256229](https://github.com/ersingundem/larenor/actions/runs/34349256229)
5.438 Flutter, 4.302 Linux Server, 98 Android native ve 17 gerçek API 35 E2E
testini geçti; gerçek Linux supervisor testi atlanmadı.
[Security 34349256017](https://github.com/ersingundem/larenor/actions/runs/34349256017)
üç işiyle yeşil. Eşit user map'leri tek başına initial host namespace veya
remap-disabled başlangıç kanıtı sayılmaz; `installAvailable=false` korunur.

`422eb80` → `5580f66` ve `ffba1a7` → `5c81207` TDD dilimleri, supervisor'ın
socket-bound proc/root tanıtıcılarından daemon `cmdline` ve daemon köküne göre
çözülen exact `daemon.json` kanıtını no-follow dosya tanıtıcılarıyla tutuyor.
`/version` ile `/v1.47/info` aynı doğrulanmış bağlantıda ve ortak deadline içinde
okunuyor. Peer ve worker için root credentials, tam initial kimlik haritası ve
aynı user namespace zorunlu; başlangıç argümanında veya config'te
`userns-remap`, Engine güvenlik seçeneklerinde `rootless`/`userns`, yanlış
platform, duplicate/bozuk JSON, config değiştirme/yerine koyma ya da deadline
kaybı bütün worker kanıtını etkiden önce kapatıyor. Runtime güvenlik seçenekleri
her effect öncesi/sonrası yeniden okunuyor. Yeni iki modülün **60 testi**
ve kurulum/kimlik/Engine yollarını içeren geniş ilgili paket yerelde geçti.
Exact `b6c8ede` kaynağında tam Server paketi **4.351 PASS / 13 macOS platform
skip** verdi; Security policy, compileall, diff ve kuyruk doğrulaması temiz. Bu yerel kanıt
henüz exact Linux CI veya bağımsız review değildir.

S08.7 üç sonlu teslimden oluşur: **kaynak bağlama ve typed durum → komut ve
kalıcı sonuç → açık Direct aktarımı**. Üç yerel dilim de squash yapılmadan
main'e alındı. Server gerçek HTTP/SQLite/loopback ile kaynak bağlama, yetkili
switch durumu, sınırlı cache ve AES-GCM ile saklanan idempotent komut makbuzu
sağlıyor. Client Core kaynak satırında Aç/Kapat, açık sonuç durumu ve kaybolan
POST yanıtı için yalnız GET kullanan kurtarma akışı sunuyor. DNS/bağlantı/TLS
sonrasında ve ilk HTTP baytından hemen önce yetki/revision yeniden denetleniyor;
eski snapshot yarışları cache nesliyle engelleniyor. Provider yalnız `200`
sonucunda accepted; `400/401/403/404/405/422` rejected ve diğer sonuçlar
unknown. Otomatik retry ve Direct fallback yok.

Açık Direct aktarımı yalnız PIN ile açılan Ayarlar akışında kayıtlı tek HA
URL/token çiftini ve seçilmiş mevcut, boş bir Core switch kaynağını önizler.
Server 60 saniyelik, tek kullanımlık önizlemeden sonra şifreli service, binding
ve sonuç makbuzunu tek SQLite transaction'ında yazar; Client Direct kayıtları
değiştirmez. Oda, sahne, betik, diafon, web-origin izni veya diğer servisler bu
dar aktarımda taşınmaz. Kayıp onay yanıtı yalnız sonuç GET'iyle kurtarılır;
confirm tekrarlanmaz. Güncel admin, kaynak WRITE/revision, PIN, hesap, ev,
pencere ve rota bağlamı ağ öncesinde ve sonrasında yeniden denetlenir.
Gerçek Server HTTP sözleşmesinin 15 kaydı Client'ta 14 HTTP isteği ve değişmiş
confirm'in ağ öncesi reddiyle eşleşti; sözleşme SHA-256 değeri sabit kaldı.

Yeni [salt okunur domain dilimi](core-ha-readonly-domains-implementation-2026-09-09.md)
`domain.object_id` biçimindeki standart ve özel HA varlıklarını kapalı
`kind/state/commandAvailable` projeksiyonuna aldı. Attributes ve upstream
kimlik/sır alanları aktarılmıyor; 255 karakteri aşan veya kontrol karakteri
içeren state reddediliyor. Switch dışındaki domain'ler admin WRITE izninde
bile komut yayınlamıyor, HA'ya POST göndermiyor ve komut journal'ına kayıt
yazmıyor. Android salt okunur ham durumu gösteriyor; `unknown` ile
`unavailable` ayrımını koruyor. Direct aktarımı switch-only kaldı. Yerel ilgili
**200 Server + 219 Android PASS**, tablet matrisi ve analiz temiz; exact-source
CI ve fiziksel cihaz kabulü açık.

Yerel birleşik Server koşusu ortam değişkeni eksikken **3.851 PASS, 12 macOS
platform skip ve 4 setup error** verdi; sabit `apksig 9.1.0` JAR hash'i ve
Homebrew Java 17 yolu doğrulandıktan sonra bu dört kripto testi ayrıca **4/4
PASS** oldu. Bu iki koşu tek temiz tam suite diye toplanmaz. Direct Server
odaklı **87 PASS**, Client odaklı **92 PASS**, Client ilgili **599 PASS**;
yeni Server modülleri %95,93 ve yeni Client modülleri %95,88 satır kapsamı
verdi. Birleşmiş main üzerinde Direct Client **92 PASS**, analiz0 ve 19 dosyada
format farkı0 tekrarlandı. Server ile Client bağımsız kaynak incelemeleri ve
TR/EN 2× 600/1280 gerçek-font tablet görselleri temiz. Exact-source uzak CI ve
APK122 geçti; geniş HA varlık/servis kapsamı ve fiziksel kabul bekliyor.
[Server kanıtı](core-ha-switch-server-implementation-2026-09-08.md) ·
[Client kanıtı](core-ha-switch-client-implementation-2026-09-08.md) ·
[Komut ve makbuz kanıtı](core-ha-switch-command-implementation-2026-09-08.md) ·
[Direct Server aktarımı](direct-ha-migration-server-implementation-2026-09-08.md) ·
[Direct Client aktarımı](direct-ha-migration-client-implementation-2026-09-08.md) ·
[Uygulama planı](core-home-assistant-adapter-plan-2026-09-06.md).

İlk exact-source uzak paket `32d43fd` üzerinde Security ve ayrı Server
Container koşuları geçti; Server **3.867 PASS** ve amd64/arm64 container
manifestini tamamladı. Android işinde tam Flutter **5.436 PASS**, debug APK ve
emülatör **17/17** yolculuk geçti. Aynı workflow'un bağımsız Server kopyası
**3.866 PASS** sonrasında yalnız sentetik volume test sunucusunun isteğe bağlı
ikinci isteği beklerken `socket.timeout` kaydetmesiyle bir fixture hatası verdi;
bu nedenle imzalı APK işi çalışmadı. Tek tam Android logunun SHA-256 değeri
`494e06e10e58a79dcbf2e7ab24846cac64afb54763c45d8640ef71371993eb10`.
Üretim etkisi olmayan yedi satırlık fixture düzeltmesi gerçek 3 RED→4 GREEN,
son 612 ilgili PASS/3 mevcut macOS skip ve paralel 8×4 PASS ile main'e alındı;
ilk GET, başlık/gövde sınırları, callback hataları ve çağrı sayısı korunuyor.
[Fixture yaşam döngüsü](volume-create-fixture-lifecycle-repair-2026-09-08.md).
İkinci exact-source paket `bd1a604` üzerinde bu yarış kapandı. Security, ayrı
Server Container **3.867 PASS**, amd64/arm64 imaj ve manifest yayını; Android
workflow'unda **5.436 Flutter PASS**, **3.867 Server PASS**, debug/native
sözleşmeleri ve API 35'te **17/17 E2E** geçti. İmzalı **APK122** üretildi ve
yerel resmi `apksig 9.1.0` doğrulamasında `com.ersingundem.larenor`,
`versionCode=100000122`, `minSdk=26`, `debuggable=false`, beklenen sertifika ve
geçerli imza olarak doğrulandı. APK 122.207.785 bayt; SHA-256
`21cc73b9c471ad08c21e010c8cf382410ce57d539ca1b9c395c42fd3064ca94b`.
Bu CI/artefact kabulü Direct→Core ve ortak tablet paketini doğrular; fiziksel
Huawei/DeX/TalkBack ve geniş Home Assistant varlık/servis kapsamı açık kalır.

Arşiv E2E yardımcısındaki rota-sahipliği yarışı exact `e97189f` üzerinde
kapandı. Güncel ve dokunulabilir izinli rota içinden tek dikey kaydırma sahibi
seçiliyor; küçük 420×400/2× HomeSource görünümü ve gerçek Archive geçişi
regresyon testleriyle korunuyor. İlgili 200 yerel test ve analiz temizdi;
uzak Android CI **5.438 Flutter PASS**, **3.934 Server PASS** ve API 35'te
**17/17 E2E** verdi. İmzalı **APK125**, bağımsız Security ve Server Container
işleri de aynı exact source üzerinde geçti. Bu kanıt test yarışını kapatır;
fiziksel cihaz kabulünün yerine geçmez.

[Services tablet paketi](core-services-tablet-accessibility-2026-09-06.md):
46 yeni ve 186 ilgili test geçti; tam bağlantı adları, 48px hedefler, görünür
klavye odağı ve tek adımlı IME geçişi düzeltildi.
[Core hesap formları](core-account-ime-navigation-2026-09-08.md):
12 gerçek hata yeniden üretildi; son 24 IME ve 163 ilgili test geçti.
Üretimde yalnız yinelenen iki odak geçişi kaldırıldı. Bu iki paket exact
`5cbff21` / APK116 ile temiz CI ve bağımsız imza kapısından geçti. Önceki birleşik
Client koşusu `cd961ac` üzerinde tamamlandı; Mac'in uzun
bakım uykularıyla çakışan iki 90 saniyelik test zaman aşımı kaydedildi. Bu koşu
başarılı sayılmıyor. Kaynak ve test süreleri değiştirilmeden iki testin odaklı
tekrarı **2 PASS**, tam analiz **0 sorun** ve biçim kontrolü **973 dosya / 0 fark**
verdi. [Birleşim ve korunan başarısız koşu](core-services-ime-integration-2026-09-08.md).
Bu önceki başarısız yerel koşu tarihsel kanıt olarak korunur; CI116 aynı
kaynağın devamında 5.220 Flutter testinin tek koşuda geçtiğini doğrular.

[Jellyfin yönetilen kurulum planı](jellyfin-managed-volume-installation-plan-2026-09-06.md)
dört adımdır: gerçek image/UID karakterizasyonu, onu tüketen mount/kurulum akışı,
güncel yönetici/worker yetkisi ve özel ilk hesap ile doğrulanmış Core bağlantısı.
[Helper fixture](jellyfin-storage-fixture-implementation-2026-09-08.md)
main ile birleşti: **87 odaklı ve 261 ilgili test geçti**. Bağımsız incelemede
bulunan build context ve kaynak değişimi sorunları gerçek RED/GREEN ile
kapatıldı; son kaynak incelemesi temiz. Manuel native amd64/arm64 CI hazırlığı ve kaynak incelemesi tamamlandı:
122 fixture/launcher ve 215 politika testi geçti.
[Birleşik yayın hazırlığı](services-ime-native-ci-preparation-2026-09-08.md).
İlk manuel native amd64/arm64 koşusu iki mimaride de genel karakterizasyon
hatasıyla kapandı ve makbuz üretmedi. Kapalı phase/hata kodu tanılaması
8 RED→8 GREEN, toplam 139 odaklı test, 215 politika testi ve %96,09 dal dahil
kapsamla main'e alındı. [Tanılama kanıtı](jellyfin-native-storage-diagnostics-2026-09-08.md).
Bu aşamada kesin neden tahmin edilmiyor.
İkinci koşu her iki mimaride de `helper_build / fixture_command_failed` verdi;
bu, kaynak/daemon/imaj/volume/staging kapılarının geçtiğini daralttı. Helper build
altında exit, çıktı sınırı, zaman aşımı, spawn ve I/O hatalarını ham stderr
taşımadan ayıran ek tanılama 5 RED→5 GREEN, toplam 152 test, 215 politika testi
ve %96,49 dal dahil kapsamla main'e alındı.
[Helper build tanılama kanıtı](jellyfin-helper-build-diagnostics-2026-09-08.md).
Üçüncü koşu iki mimaride de `helper_build / fixture_command_exit_failed`
verdi: child gerçekten nonzero çıktı; timeout, stdout sınırı, spawn ve I/O
sınıfları elendi. Yalnız helper build stderr'ini 64 KiB özel RAM sınırında
drain edip bilinen Docker hata ailelerini sabit kodlara dönüştüren son tanılama
12 RED→12 GREEN, toplam 172 ilgili test, 215 politika testi, %96,48 dal dahil
kapsam ve bağımsız CLEAR ile main'e alındı. Ham stderr, path, URL, env veya sır
log/artifact'a çıkmaz; belirsiz/taşan veri genel kapalı kod olarak kalır.
[Özel build tanılama kanıtı](jellyfin-private-build-errors-2026-09-08.md).
Bu sınıflandırıcıyı içeren dördüncü native koşu `34240514836`, exact
`42bbcf6` üzerinde iki mimaride de yine
`helper_build / fixture_command_exit_failed` verdi; bounded stderr bilinen bir
hata ailesine uymadı. Kök neden çıkarılmadı. Sonraki koşunun helper build'den
önce exact, digest-pinned Python base imajını pull/inspect/create/start/result
sınırlarında ayrı sınaması main'e alındı: 38 yeni, toplam 210 ilgili test ve
215 politika testi geçti; dal dahil kapsam %97,02 ve bağımsız inceleme temiz.
[Exact base runtime probe](jellyfin-helper-base-runtime-probe-2026-09-08.md).
Beşinci native koşu `34250089907`, exact `25d438a` üzerinde pull, image inspect,
create ve created-state kapılarını iki mimaride geçti; exact base
`start --attach` aşaması `fixture_command_failed` verdi. Tek indirilen logun
SHA-256 değeri
`c7444904c1bbeecb7f49d14725aeeb4d068800022938cc409b6fb24771cc9cd0`.
Bu start çağrısında stderr toplamadan mevcut nonzero/timeout/output-limit/
spawn/I-O sınıflarını açan dar tanı main'e alındı: 15 yeni, toplam 225 ilgili
test ve 215 politika testi geçti; dal dahil kapsam %97,18, bağımsız inceleme
temiz. [Attached start tanısı](jellyfin-base-start-process-diagnostics-2026-09-08.md).
Altıncı native koşu `34257672707`, exact `32d43fd` üzerinde iki mimaride de
`helper_base_start / fixture_command_exit_failed` verdi. Tek indirilen log
70.211 bayt, SHA-256
`f5357a2f73df32572efcf306599d621609fe215e8d5347237c082b34e44acbb1`.
Bu, CLI sürecinin nonzero çıktığını kanıtlar; attach, start, wait veya container
çıkışı arasında kök neden seçmez. Yalnız exact attached base start çağrısında
64 KiB + 1 bayt özel stderr drain eden kapalı tanı main'e alındı: 10 gerçek
RED→10 GREEN, 32 yeni, toplam 257 ilgili ve 215 politika testi geçti; runner ve
launcher dal dahil kapsamı %97,28, bağımsız inceleme temiz. Ham stderr hiçbir
çıktıya yazılmaz; tek leaf wrapper'a üstün, birden çok leaf ambiguous, boş veya
eşleşmeyen mesaj eski genel hata olarak kalır. 20 saniye/128 bayt stdout, tek
deneme ve process-group cleanup değişmedi.
[Private start tanısı](jellyfin-base-start-private-stderr-2026-09-08.md).
Birleşmiş main üzerinde Jellyfin, Engine HTTP ve volume ailesinin **847 PASS /
3 mevcut macOS skip** koşusu da geçti. Yedinci native koşu `34260536889`, exact
`bd1a604` üzerinde iki mimaride yine
`helper_base_start / fixture_command_exit_failed` verdi; bounded stderr bilinen
bir aileyle eşleşmedi. Tek indirilen log 70.222 bayt, SHA-256
`8ac144f5069622b8bcb5fd63d55bbdcfd9d481fd92637f599005df91ec8a70c4`.
Başarısız tek start denemesinden sonra yalnız aynı sahipli containerın `.State`
alanını 10 saniye/64 KiB sınırında okuyan tanı yerelde hazır: 15 RED→15 GREEN,
249 son Jellyfin ve 215 politika testi geçti; runner+launcher dal dahil kapsamı
%98'e yuvarlandı. OOM/dead/running/exited-nonzero sonuçları kapalı ve neden
iddiası taşımayan kodlara dönüşür; bozuk/okunamayan durum eski kapalı kodu
korur. İki inceleme P2'si kapatıldı ve final bağımsız inceleme CLEAR.
[State tanısı](jellyfin-base-start-state-diagnostics-2026-09-08.md).
Bu state tanısı tek başına Engine/install kabulü sayılmadı.
Sekizinci koşu `34263828110`, exact `18b4623` üzerinde arm64'te
`helper_base_wait_failed`, amd64'te `fixture_command_exit_failed` verdi; başarı
makbuzu yok. Tek indirilen 70.190 bayt logun SHA-256 değeri
`27dbd3a1724475af715faa1e2c4cd5e4d3c5350a2b0cca92aeb91a28611b4a82`.
Bu mimariye göre farklı sonuç tek ortak neden iddiasını desteklemiyor. Mevcut
bounded state gözleminde kalan iki olgusal sonuç yerelde ayrıldı: boş hata ile
`exited/0` ve `created/0`. İki gerçek RED kapandı; 15 state, toplam 251
Jellyfin ve 215 politika testi geçti. Tek start/inspect, redaksiyon ve cleanup
değişmedi; bağımsız final inceleme CLEAR.
[Zero-state tanısı](jellyfin-base-zero-state-diagnostics-2026-09-08.md).
Dokuzuncu koşu `34267014037`, exact `63b25f8` üzerinde iki mimaride de
`helper_base_start / fixture_command_exit_failed` verdi; başarı makbuzu yok.
Tek indirilen 70.203 bayt logun SHA-256 değeri
`85f0cd8e7c8308e42062b00eeaf9870f4d99c328d822a1169b7fd64fe8384076`.
Zero-state kodlarından hiçbiri gözlenmedi. Genel start sonucu için state
okunamadı/geçersiz/sınıflandırılmadı ayrımı yerelde eklendi; daha güçlü wait,
timeout, permission ve runtime gözlemleri korunuyor. İlk altı RED ile incelemede
bulunan Unicode/Recursion P2'sinin iki gerçek RED'i kapandı; 21 state, toplam
257 Jellyfin ve 218 politika testi geçti. Tek bounded inspect, redaksiyon,
cleanup ve no-retry sınırları değişmedi; bağımsız final inceleme CLEAR.
[State-read tanısı](jellyfin-base-state-read-diagnostics-2026-09-08.md).
Onuncu koşu `34270629266`, exact `e97189f` üzerinde iki mimaride de
`helper_base_start / helper_base_state_unclassified` verdi; başarı makbuzu yok.
Tek indirilen 70.215 bayt logun SHA-256 değeri
`27e931c6eaa35470d68a329cfc010e34a0b99f143fc38e57a152da8fbd683f58`.
Bu, tek bounded state okumasının typed ve geçerli olduğunu doğruladı. Kalan
şekil, ham hata metni taşınmadan unknown error, created/nonzero, unknown status
ve diğer bilinen status olarak ayrıldı. Dört gerçek RED kapandı; 28 state,
toplam 264 Jellyfin ve 218 politika testi geçti. İncelemede geçerli Docker
`removing` durumuna “tutarsız” denemeyeceği nötr kategoriyle güvence eklendi;
final bağımsız inceleme CLEAR.
[State-shape tanısı](jellyfin-base-state-shape-diagnostics-2026-09-08.md).
On birinci koşu `34273975969`, exact `bd03125` üzerinde iki mimaride de
`helper_base_start / helper_base_state_error_unclassified` verdi; başarı
makbuzu yok. Tek indirilen 70.209 bayt logun SHA-256 değeri
`37654a4e183b644beaeffc175234e1d0350e195ef6039d5bb58326e5bdd0baad`.
Bu sonuç typed state içindeki boş olmayan hatayı doğruladı ancak metni veya
nedeni açığa çıkarmadı. Kalan hata cgroup/security-profile/namespace/mount,
host kaynağı, yol, kimlik ve yapılandırma ailelerine yerelde ayrıldı; çoklu
eşleşme ayrı kapalı ambiguous sonucuna gider. Beş gerçek RED kapandı; 34 state,
66 state+stderr, toplam 270 Jellyfin ve 218 politika testi geçti. Tek bounded
inspect, redaksiyon, cleanup ve no-retry sınırları değişmedi; exact commit için
bağımsız inceleme CLEAR.
[State-error aileleri](jellyfin-base-state-error-families-2026-09-08.md).
On ikinci koşu `34276890501`, exact `282bcc1` üzerinde iki mimaride de
`helper_base_start / helper_base_path_failed` verdi; başarı makbuzu yok. Tek
indirilen 70.199 bayt logun SHA-256 değeri
`555a81b36a5713364ffdef8a658be8d76a763f832e1ec678329c08ff199e0cba`.
Bu sonuç image/proc/sys/runtime/Engine/host yol konumu ailelerine yerelde
ayrıldı; çoklu eşleşme ambiguous, bilinmeyen konum generic kalıyor. İlk yedi
RED ile incelemede bulunan “missing” ENOTDIR yanlış iddiası ve çıplak runtime
adı P2'leri gerçek regresyonlarla kapandı. 43 state, 75 state+stderr, toplam 279
Jellyfin ve 218 politika testi geçti. Tek bounded inspect, redaksiyon, cleanup
ve no-retry sınırları değişmedi.
Exact commit için bağımsız final inceleme CLEAR.
[Yol-konumu tanısı](jellyfin-base-path-location-diagnostics-2026-09-08.md).
On üçüncü koşu `34279647850`, exact `8f07560` üzerinde iki mimaride de
`helper_base_start / helper_base_path_location_ambiguous` verdi; başarı
makbuzu veya artefakt yok. Tek indirilen 70.214 bayt logun SHA-256 değeri
`a8e7ac3ee4053ffc9673c91fa7de1a7f08d732f5be3926a34588efe7eb9634fb`.
Engine kökü ile image/proc/sys/runtime/host hedefini aynı path belirtecinde
kanıtlayan beş ilişki ayrıldı. İki ayrı yolun tek ilişki sayılması P2'si gerçek
RED ile kapandı; üç aile veya bağımsız iki yol ambiguous kalıyor. 50 state, 82
state+stderr, toplam 286 Jellyfin ve 218 politika testi geçti. Exact commit için
bağımsız final inceleme CLEAR. Tek bounded inspect, redaksiyon, cleanup ve
no-retry sınırları değişmedi.
[Yol-ilişkisi tanısı](jellyfin-base-path-relation-diagnostics-2026-09-09.md).
Exact `8f07560` Server Container ve Security CI geçti. Android debug, analiz,
5.438 Flutter testi ve 17/17 E2E geçti; yeniden kullanılan Server işi eski 15
dakikalık sınırda iptal edildiği için imzalı paket atlandı. `3dbdde2` test
kapsamını değiştirmeden bu bounded sınırı 20 dakikaya çıkardı. Exact `1e73ea3`
yeniden koşusunda tam Server kapısı, 17/17 E2E ve imzalı APK129 başarıyla geçti.
On dördüncü koşu `34281674390`, exact `1e73ea3` üzerinde iki mimaride de
`helper_base_start / helper_base_path_location_ambiguous` verdi; başarı
makbuzu veya artefakt yok. Tek indirilen 70.207 bayt logun SHA-256 değeri
`81409d865a87f785bda58094a978344e4ed37d6817f1562184744a8da5309bed`.
Engine kökü ile image/proc/sys/runtime/host ailelerinin exact ikili birlikte
görülmesi beş nötr `*_paths_observed` koduna ayrıldı; aynı token ilişkisi daha
özel kalıyor, üçlü ve diğer kümeler ambiguous. Beş gerçek RED kapandı; 54
state, 86 state+stderr, toplam 290 Jellyfin ve 218 politika testi geçti.
Bağımsız final inceleme CLEAR; tek inspect/no-retry/redaksiyon/cleanup sınırları
değişmedi.
[Path birlikteliği tanısı](jellyfin-base-path-cooccurrence-diagnostics-2026-09-09.md).
On beşinci koşu `34284431981`, exact `d5d5889` üzerinde iki mimaride de
`helper_base_start / helper_base_engine_proc_paths_observed` verdi; başarı
makbuzu veya artefakt yok. Tek indirilen 70.226 bayt logun SHA-256 değeri
`6a22d9e663d17e2856a7ac445d0f5a754e82725bd7b53147bc769c4f1e9a9d20`.
Procfs gözlemi sys/net, self fd, exact mountinfo, self namespace ve sayısal
process namespace/fd alt ailelerine ayrıldı. `/proc/sys` artık sysfs sayılmıyor;
başka köklerdeki benzer metin ve `mountinfo-private` iki gerçek review RED ile
kapandı. Son exact kod Python 3.12.14 altında 64 state, 96 state+stderr, toplam
300 Jellyfin ve 218 politika testini geçti. Bağımsız final inceleme CLEAR.
Aynı kodu taşıyan exact `5407011` izole Server
CI koşusunda 3.977 test geçti.
[Procfs alt yol tanısı](jellyfin-base-proc-subpath-diagnostics-2026-09-09.md).
On altıncı koşu `34287061380`, exact `b4e8620` üzerinde iki mimaride de
`helper_base_start / helper_base_proc_process_namespace_observed` verdi;
başarı makbuzu veya artefakt yok. Tek indirilen 70.230 bayt logun SHA-256
değeri `c9ba3dd9cbd9891036426bc927aa79538a5c49eb8dac48f1e3ffb10c876cb83a`.
Sayısal süreç namespace yolu net/mnt/ipc/uts/pid/pid-child/user/cgroup/time/
time-child yapraklarına ayrıldı; PID kapalı kodlara girmez. Path metni genel
hata imzalarından ayrılarak `cgroup` yaprağının izolasyon hatası sanılması
önlendi. On bir gerçek RED kapandı; son exact kod 75 state, 107 state+stderr,
toplam 311 Jellyfin ve 218 politika testini geçti. Bağımsız final inceleme
CLEAR. Exact `ce5479a` izole Server CI koşusunda 3.988 test geçti.
[Process namespace tanısı](jellyfin-base-process-namespace-diagnostics-2026-09-09.md).
On yedinci koşu `34289499126`, exact `d7b2027` üzerinde iki mimaride de
`helper_base_start / helper_base_proc_process_net_namespace_observed` verdi;
başarı makbuzu veya artefakt yok. Tek indirilen 70.235 bayt logun SHA-256
değeri `0db35348fe1aff1f7177b174b5e961fe206e41d4d95c93693ca6dae290b65c09`.
PID namespace içinde host procfs görünümünü bırakma adayı yerel testlerde
311 Jellyfin ve 218 politika testini geçti; ancak bağımsız inceleme iç thread
kimlikleri ile procfs sayı uzayını ayırdığını gösterdi. Aday Native'e
gönderilmeden geri alındı. `30a2b3b` onarımı mount-only daemonı transient
systemd servisine, helper ve Jellyfin süreçlerini aynı servisin ayrı
`containers` cgroup alt ağacına alır. Systemd kimliği, invocation, ana PID ve
cgroup inode'u iki aşamada doğrulanır; temizlik yalnız önceden açılmış
`cgroup.kill` ve aynı `cgroup.events` descriptorlarıyla yapılır. Launch yanıtı
belirsizse aynı adlı servis sonradan sahiplenilmez. 351 Jellyfin ve 219 politika
testi geçti; bağımsız final inceleme CLEAR. Exact-source izole Server CI
[34293524785](https://github.com/ersingundem/larenor/actions/runs/34293524785)
4.027 testi iki uyarıyla geçti. Paket `6a054ea` olarak main'e alındı. Native18
[34294788670](https://github.com/ersingundem/larenor/actions/runs/34294788670)
aynı exact kaynak üzerinde amd64 ve arm64 karakterizasyonunu, platform/source
makbuz doğrulamasını ve iki public artifact yüklemesini geçti. İndirilen iki
1.753 bayt makbuz yerelde aynı verifier ile yeniden doğrulandı; iki volume,
bir restart, hazır imaj ve iki `observed_requires_bootstrap` sonucu taşırken
`bootstrapAccountConfigured=false` ve `installAvailable=false` kaldı. S06.3d
iki mimarili native kabulü kapandı. Main Server Container
[34294585502](https://github.com/ersingundem/larenor/actions/runs/34294585502)
4.027 testten sonra iki mimari image build/smoke ve manifest yayınını da geçti;
Security `34294584966` başarılı. S06.3f tam kaynak makbuzu sıradaki kapıdır.
Android
[34294585430](https://github.com/ersingundem/larenor/actions/runs/34294585430)
aynı exact kaynakta 5.438 Flutter, 17 API 35 E2E ve 4.027 Server testini,
native platform kontrollerini ve imzalı APK135'in paket/imza/sürüm
doğrulamasıyla Larenor Server yayımını geçti.
[Sahiplikli cgroup yaşam döngüsü](jellyfin-owned-cgroup-lifecycle-2026-09-09.md).
Gerçek ev kurulumu ve kullanıcı kurulum yetkisi hâlâ açık;
`installAvailable=false`.

S06.3f için ayrı native kaynak fixture’ı yalnız katalogda sabit Jellyfin
image’ını pull/inspect eder ve tek iç control network’ü create/list/full-ID
inspect ile doğrular. Aynı journal kapatılıp yeniden açıldığında hazır
makbuzların hiçbir Engine I/O’su veya yeni yetki istemeden okunabildiği kapalı
bağımlılıklarla sınanır. Public makbuz ham network ID veya preparation ID
taşımaz; yalnız ağ kimliğinin SHA-256 değerini, kaynak dosyalarının özetlerini,
`containerOperations=0` ve `installAvailable=false` değerlerini içerir.
İlk incelemede ortak daemon açılışındaki tek `docker info` CLI çağrısı kabul
sınırını aştığı için ilk uzak CI iptal edildi. Kaynak fixture daemon’ı artık
canlı systemd MainPID ve `/proc/<pid>/cmdline` değerini baştan sona sabit argv
ile doğruluyor; bütün Docker CLI çağrılarını kapalı hata ile reddediyor. Odaklı
44 test, ilgili 674 test ve güvenlik politikası yerelde geçti. Tam 4.284
testlik yerel koleksiyonda yalnız zorunlu apksig ortamı verilmediği için dört
setup hatası oluştu; sabit apksig 9.1.0 SHA-256 doğrulandıktan ve Homebrew Java
17 yolu verildikten sonra bu dört kriptografik test 4/4 geçti. Exact-source
Exact `191baf3` Server CI 4.0k+ test paketiyle geçti. Managed v2 create/start için
ayrı kaynak-bağlı amd64/arm64 workflow ve kapalı receipt verifier `3be1dc6`
üzerinde yerelde hazırlandı; bu yeni workflow'un iki native artifact'i henüz
bekleniyor.
[Yerel kaynak kabul kaydı](media-resource-native-acceptance-2026-09-09.md).

İlk main bütünlük tekrarında bağımsız Server CI 4.064 PASS ve native iki mimari
PASS olmasına karşın Android ile Server Container’ın eşzamanlı reusable Server
işleri aynı sentetik volume `False-arm64` varyantında `uncertain` verdi. Hedef
test 20 seri ve 64 paralel tekrar geçti. Fixture’ın HTTP header okuyucusunda
byte başına socket syscall üreten yol bloklu, 16 KiB ile sınırlı ve header ile
aynı pakette gelen body’yi koruyan okuyucuya çevrildi; ürün Engine timeout veya
retry davranışı değiştirilmedi. İlgili 307 test ve yük altında ikinci 64 tekrar
geçti. Güncel exact-source main CI bu fixture commit’i için yeniden koşmalıdır.

## Önceki canlı takip notları (arşiv)

- [Yürütme kuyruğu](EXECUTION_QUEUE.md): durumlar, bağımlılıklar ve kabul kapıları.
- [Makinece doğrulanan kuyruk](execution-queue.json): tamamlanan ve kalan 125 iş.
- [GitHub Actions](https://github.com/ersingundem/larenor/actions): gönderilmiş kaynağın canlı CI durumu.
- [Ürün planı](product-implementation-plan-2026-09-05.md), [Core/Client mimarisi](server-client-architecture-2026-09-05.md) ve [test matrisi](testing-matrix-2026-09-05.md).

Her doğrulanan dilimden sonra bağımlılıkları hazır sıradaki yazılım işine
geçilir. Aynı Codex görevindeki “Larenor geliştirme ve bakım” takibi 15 dakikada
bir planı ve yarım kalan işleri kontrol eder; ikinci çakışan yürütücü açmaz.
Mac/Codex açık ve erişilebilir olmalı, kullanım hakkı bulunmalıdır. Yerel
uyku veya kullanım sınırı sırasında çalışma kesilebilir; bu dosya tek başına
arka plan servisi değildir. Takip Codex'in zamanlanmış görevlerinden durdurulabilir.

Günlük GitHub depolama bakımı Türkiye saatinde 03.15 sonrasında en fazla bir
kez çalışır. **8 Eylül: 7 eski debug APK, 909.621.176 bayt temizlendi**;
en yeni üç debug APK ve bütün imzalı APK/test raporları korundu. Silinen ID'lerin
artık bulunmadığı ve korunanların durduğu taze envanterle doğrulandı.
GHCR paketleri silinmedi. [Saklama politikası](github-storage-retention.md).

Önceki başarısız [CI105](client-delivery-105-2026-09-06.md) ve
[CI106](client-delivery-106-2026-09-06.md) kanıtları değişmedi;
[CI108 öncesi kuyruk kayıtları](restore-people-evidence-before-ci108-acceptance-2026-09-08.json)
ayrı korundu. Yeni 63 özellik sayacı **0/63**; yazılan planlar kabul edilmiş
özellik olarak gösterilmiyor.

## Önceki teslim kayıtları

Aşağıdaki kayıtlar kendi tarih ve kaynaklarına aittir; güncel durum yukarıdadır.

**CI102 sonuçlandı: Core ve güvenlik geçti; Android teslimi durdu.**
Exact `38bc2bc` kaynakta Linux3.203, Flutter4.417, güvenlik207, JVM98 test geçti.
E2E13 PASS/1 FAIL: onuncu logout yolculuğu test verisindeki `ref.id` yerine
`id` okuduğu için mount öncesinde düştü; imzalı APK102 üretilmedi.
[Sonuç ve hata kaydı](client-delivery-102-2026-09-06.md).
Dar fixture onarımı `2cced39` GitHub'a gönderildi: yeni regresyon RED→GREEN,
88 ilgili test ve tam analiz geçti; bağımsız kaynak incelemesi temiz.
[Android103](https://github.com/ersingundem/larenor/actions/runs/34012091515),
[Core](https://github.com/ersingundem/larenor/actions/runs/34012091577) ve
[güvenlik](https://github.com/ersingundem/larenor/actions/runs/34012091354)
CI103 sonuçlandı: Core3.203 ve güvenlik207 geçti; Android13 PASS/1 FAIL,97/99 faz.
Çıkış sonrası yeniden kurulan ekran geçici olarak yokken test erken okuma yaptı.
[Başarısız koşu ve sınırları](client-delivery-103-2026-09-06.md) korunur.
Dar bekleme onarımı `64bdf58`: RED1 PASS/2 FAIL→GREEN3 PASS;91 destek testi,
tam analiz0 ve899dosya biçim kontrolü geçti; bağımsız inceleme temiz.
[Android104](https://github.com/ersingundem/larenor/actions/runs/34013071464),
[Core31](https://github.com/ersingundem/larenor/actions/runs/34013071566) ve
[güvenlik104](https://github.com/ersingundem/larenor/actions/runs/34013071378)
sonuçlandı: Core Linux3.203, güvenlik207, Flutter4.421 ve JVM98 geçti.
Android14 E2E/99faz ve bağımsız imzalı APK104 teslimi de doğrulandı.
[Sonuç](client-delivery-104-2026-09-06.md).

**S08.5 başladı:** logout'ta başarısız kalıcı silme sonrası eski oturumun geri
kullanılması ve gecikmiş hatanın Core ana ekranında görünmemesi gideriliyor.
Paralelde geri yükleme önizlemesi/onayı, hedef okuma kümesi ve özel journal
aynı işleme bağlanıyor; provider kapanışında açık devir uygulanacak.
[Somut uygulama sırası ve açık sınırlar](client-restore-logout-implementation-plan-2026-09-06.md).
Logout `2911ac9`, **25 odaklı / 1.547 ilgili PASS** ve bağımsız son inceleme
ile yerelde tamamlandı. Volume Unix okuyucusu `0d86fa1` ile ayrı sonraki
`091b2bb` birleşiminde **4.415 tam Client PASS / 5:05**, **3.192 tam Core
PASS / 11 Linux skip / 5:13**, analiz0 ve896dosya biçim farkı0 elde edildi.
[Sonraki birleşim](volume-reader-integration-2026-09-06.md).
Onuncu Android çıkış yolculuğu `0bf1258` ile birleşti: **87 fixture testi**, tam analiz0 ve897dosya biçim kontrolü geçti. Eski9yolculuk/89faz aynen korundu; yeni hedef **14 E2E / 99 faz**. İki yeni host testi önceki tam koşuya dahil değil.
Restore çalışması ve yeni paketin kendi CI kabulü açık. CI101 kaynağına
bu değişiklikler eklenmedi. Ayrı restore dallarında gerçek dosya ve Server
kasası ekranları prepared journal yoluna geçiriliyor; başarısız kurtarma
sonrasında eski ekranların açılması, değişen hedefe yazma ve başka journal'a
müdahale etme sınırları RED→GREEN ile kapatılıyor. Hazırlanan restore ve Vault dalları `552e67f` yerel birleşiminde bir araya geldi.
Dosya restore376, Vault387 ilgili test kanıtı kendi dallarına aittir ve toplanmaz;
Vault erişilebilirlik ek düzeltmesi1ab3483 ile birleşti:73 ilgili test geçti.
`c0d8145` uygulama/test kaynağında **4.544 tam Client PASS / 6:09**,
analiz0 ve912dosya biçim farkı0 elde edildi. Politika testleri kontrollü
tam tekrarda207 PASS verdi. [Birleşim ve bütün sonuçlar](prepared-vault-household-integration-2026-09-06.md). Core oda arşivinin model/şifreleme/tek kullanımlık restore katmanları yerelde
birleşti: codec55 yeni/168 ilgili, controller35 yeni/159 ilgili test geçti.
Aynı Core/ev/kullanıcı ve güncel hedef sınırı bağımsız incelendi. Gerçek dosya
seçimi/önizleme/onay tablet ekranı523a07f ile birleşti: **61 yeni/410 ilgili
PASS**, yeni satır kapsamı%97,60, analiz/format12dosyada0; kaynak ve EN/TR
büyük yazı görselleri ayrıca incelendi. [Arşiv ekranı](core-layout-archive-ui-implementation-2026-09-06.md).
Arşiv Android yolculuğu56607c6 da birleşti:101 host destek testi geçti;
bunlar native kabul sayılmaz. Eski10gövde/99faz +üye8 +arşiv12 =119 faz,
hedef4platform+12uygulama yolculuğudur. Kişi admin akışı eklenirken son
birleşik test/CI hazırlanıyor; bütün S08.5 kabulü açık.

**S08.6 kişi sözleşmesi yerelde hazır:** ayrı `person` modeli46 yeni/92 ilgili
Server testi ve bağımsız kaynak incelemesiyle geçti. Eski oda/kaynak modeli
aynı kaldı. Kişi oluşturma yalnız ad/sıra kabul eder; hesap, rol, izin veya
HA kişisi bağı yaratmaz. Ayrı kişi HTTP API/şifreli SQLite kaydı104 ilgili test ve dal dahil%89 kapsamla
yerelde tamamlandı; bağlı SQLite nesnesi inceleme bulgusu kapatıldı.
İlk tam Server koşusunda eski şema test verilerinden gelen5hata bulundu.
Yalnız test verisi hazırlığı düzeltildi;137 ilgili test geçti. Son tam Server
koşusu **3.298 PASS / 11 Linux skip / 321,74sn** verdi; üretim korumaları değişmedi.
Android kişi modeli/API adaptörü yerelde birleşti:77 yeni/278 ilgili test,
analiz0 ve bağımsız inceleme geçti. Gerçek HTTP sözleşmesi birleşimde2 testle
yeniden doğrulandı. Kişi provider/controller4184289 yerelde birleşti:58 yeni/135 kişi/418 ilgili
PASS; analiz0 ve bağımsız inceleme temiz. Üye listesi, PIN korumalı admin
profilleri/izin ekranları eed3916 ile gerçek arayüze bağlandı: **55 yeni/608 ilgili
PASS**, satır kapsamı%96,29, analiz0 ve12dosya biçim farkı0. EN/TR,2×,
320/600/1280 ve klavye kontrolleri ile bağımsız inceleme geçti.
[Kişi ekranı kanıtı](home-people-ui-implementation-2026-09-06.md).
Read-only Android fixture113 destek testiyle birleşti. Üye yolculuğu754d87e
hazır: eski10gövde/99faz aynı,8yeni faz; henüz Android'de çalıştırılmadı.
Admin/ACL yolculuğu ayrıca hazırlanıyor. Önceki634bc10 kaynağında
**4.870 tam Client PASS / 5:14**, analiz0 ve931dosya biçim farkı0 vardı;
bu sayı yeni ekranları/fixture testlerini içermez. Yeni HTTP sözleşmesi dahil
son tam Server koşusu **3.300 PASS /11 Linux skip /439,183sn** verdi;
Server/contract ağacı sonraki UI birleşimlerinde aynı kaldı. Birleşimin yeni tam Client testi
ve kendi CI/APK kabulü açık; bu kişi paketi APK104'e dahil değildir.
[Model kanıtı](home-people-contract-implementation-2026-09-06.md).

**S08.4 kabul edildi:** üç madde ve 22 kayıt sınıfı exact `1c2db57` kaynağında
bağımsız son inceleme + CI/APK100 ile doğrulandı.
[İnceleme](client-boundary-acceptance-review-2026-09-06.md).
Önceki 31 alt dilim ve kapanış öncesi 14 kanıt, başarısız Android97 dahil
[özgün arşivde](client-boundary-evidence-archive-2026-09-06.json) ve
[kapanış arşivinde](client-boundary-completion-archive-2026-09-06.json) korunur.

## Önceki checkpoint notları

Aşağıdaki sonuç ve “açık/bekliyor” ifadeleri ilgili eski kaynağın tarihsel
snapshot'ıdır. Güncel kabul, sıradaki paket ve aktif işler yukarıda gösterilir.

**Önceki tam doğrulanmış yayın `a27abea` / APK 101.** Üç CI ilk denemede başarılı:
Core **3.104 PASS / 0 skip**, güvenlik **207 PASS**, Flutter **4.390 PASS**,
JVM **98 PASS**, **4 platform + 9 uygulama = 13 E2E PASS / 89 sıralı faz**.
Tam analiz0; CI formatter895 dosya,0 fark. İmzalı APK tek tam indirmeyle
ayrıca doğrulandı: sürüm `100000101`, kalıcı sertifika, minSdk26,
`debuggable=false`, paket/kaynak/SHA eşleşiyor.
[Android101](https://github.com/ersingundem/larenor/actions/runs/34005590269) ·
[Core](https://github.com/ersingundem/larenor/actions/runs/34005590288) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/34005590189) ·
[APK101 ve teslim kanıtı](client-delivery-101-2026-09-06.md).
Anonim iki mimarili Core yayını da doğrulandı; evde kurulum yapılmadı.

**Bu paketin içeriği:** ACL yönetim ekranı `ab678df`, volume journal
`f9a3faa` ve dokuzuncu Android yolculuğu `1d909b8`.
[Birleşim kanıtı](core-grants-volume-integration-2026-09-06.md).
[Önceki APK100](client-delivery-100-2026-09-06.md) ve S08.4 kabulü korunur.
Sonraki logout ve Unix okuyucusu birleşimi daha sonra APK104 ile doğrulandı. Hazırlanan restore ve kişi sözleşmesi bu pakete eklenmez.

**Önceki tam doğrulanmış yayın `4bc79dc` / APK 99.** Üç CI başarılı:
Core **2.951 PASS**, güvenlik **207 PASS**, Flutter **3.941 PASS**, JVM
**98 PASS**, **4 native + 7 uygulama = 11 E2E PASS**. Analiz sıfır bulgu,
860 dosyada sıfır biçim farkı. 65 E2E fazı sıralı tamamlandı.
[Android](https://github.com/ersingundem/larenor/actions/runs/34002121963) ·
[Core](https://github.com/ersingundem/larenor/actions/runs/34002121806) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/34002121729).
[İmzalı APK 99](https://github.com/ersingundem/larenor/actions/runs/34002121963/artifacts/9980085515)
tek tam indirme sonrası Java 17 + sabit apksig ile ayrıca doğrulandı:
kalıcı sertifika, kaynak commit, paket `com.ersingundem.larenor`, sürüm kodu
`100000099`, minSdk 26 ve `debuggable=false` eşleşti. APK SHA-256:
`099476a93aa3492c8c4aae283be8868d3c536f448ddcfecdab9c9b980a93b396`.
İki mimarili Core yayını anonim doğrulandı. Ev Core'una yayın ve cihaz
kurulumu yapılmadı. [Teslim kanıtı](client-delivery-99-2026-09-06.md).
Sonraki yerel paketler için yeni birleşik test ve CI ayrıca gerekir.

**Önceki tam doğrulanmış yayın `a2658ec` / APK 98.** Linux Server **2.919 PASS**,
güvenlik **207 PASS**, Flutter **3.422 PASS**, JVM **98 PASS**, temiz analiz,
845 dosyada sıfır biçim farkı ve **dört native + yedi uygulama = 11 E2E PASS**.
Eski scoped-layout fixture düzeltmesi gerçek Android akışını geçti. Üç workflow
ilk denemede başarılı; başarısız Android 97 kaydı aşağıda korunuyor.
[Android 98](https://github.com/ersingundem/larenor/actions/runs/34000029533) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/34000029460) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/34000029415).

[İmzalı APK 98 ve metadata](https://github.com/ersingundem/larenor/actions/runs/34000029533/artifacts/9979498174)
tek tam indirmeyle Java 17 ve sabit apksig 9.1.0 üzerinden ayrıca doğrulandı:
`com.ersingundem.larenor`, `1.0.0` / `100000098`, minSdk 26,
`debuggable=false`, kalıcı sertifika ve kaynak commit eşleşiyor. APK SHA-256:
`eac472cec2a0e9de02a2df6f1f78876ae5e4dc9c56ef7e9440fe1691690586ae`.

İki mimarili Core **hazırlık** smoke'u ve anonim kaynak/AGPL etiketli yayın
geçti: `sha256:ed365020ea6bf38200beaa8a73627111a27a87c54124f6cd30bbd234bc846410`.
Ev Server'ına yayın atlandı, cihaz kurulumu yapılmadı. Aşağıdaki yeni yerel
paketler bu APK'da bulunmaz; kendi birleşik testleri ve CI ayrıca gerekir.

**`4bc79dc` ile gönderilen birleşim:** kişisel sağlık/fotoğraf ayarları,
Jellyseerr/Bazarr/Prowlarr ve qBittorrent paketleri bağımsız incelemelerden
geçti. İlk birleşik koşu **3.665 PASS / 5 FAIL** verdi; beş hata idle testinin
eski yerel depolama hazırlığındaydı. `1b2d7d3`, gerçek gizlilik sağlayıcılarını
bekleyen test düzeltmesiyle **23/23 PASS** verdi. Ardından gerçek native
pencere odağı açığı `729d96d` ile düzeltildi: **26 odaklı / 252 ilgili PASS**,
arka plan müziği korunuyor. Son birleşik koşu `1b260ce`: **3.923 PASS / bir eski test taklidinde derleme hatası**, 4:15. `ad5f866` yalnız bu taklidin yeni Proxmox imzasını düzeltti; aynı sistem ekranının **18 testi geçti**, bağımsız inceleme temiz. Tam analiz sıfır bulgu; 860 dosyada biçim farkı yok. Bu, tek koşuda tam yeşil yerel sonuç diye sayılmıyor; yeni CI tam paketi sınayacak.
[Odak kanıtı](application-window-focus-implementation-2026-09-06.md).

**Birleşime alınan bağlantılar:** Jellyfin 98 yeni/297 ilgili, Proxmox 213 odaklı/665 ilgili test ve bağımsız inceleme ile tamamlandı. Keenetic sonraki ayrı pilotta. Jellyfin'de
başarısız credential yazısının eski doğrulanmış bağlantıyı bırakması düzeltildi;
aynı durum yedi API-key bağlantısında 370 ilgili test ve bağımsız incelemeyle düzeltildi. Dashboard WebviewTile için kaynak sahipliği düzeltmesi `0a742a9` ayrı yerel diliminde **79 ilgili test** ve bağımsız inceleme ile geçti; yeni yayın paketine henüz dahil değil. Bu incelemeler tüm
entegrasyon API'lerinin veya fiziksel cihazların kabulü değildir.

**Yeni yerel birleşim hazırlanıyor:** Keenetic kayıt/PIN/kurtarma pilotu
`dc87062` **1008 ilgili PASS**, Wi-Fi/cihaz/port ekranı koruması `74e3f44`
**1047 ilgili PASS** ve bağımsız inceleme ile tamamlandı. Dashboard WebView,
Core yönetim ekranı ve volume gözlemi aynı sonraki pakete alındı.
[Birleşim kanıtı](core-client-integration-2026-09-06.md) tam test/CI aşamasını izler.
`8d9e4d2` birleşik üretim/test kaynağı **4.271 Client testi / 4:48** ile geçti;
207 güvenlik/CI araç testi ve backup/CI politika kontrolü de temiz. Tam Server
**3.040 PASS / 10 Linux'a özgü skip / 8:17,88** verdi. Tam analiz 0 bulgu,
878 dosyada biçim farkı yok. Sonraki `bb6ed4e` birleşimi sekizinci Android
metadata yolculuğunu ekledi: tüm fixture klasörü **48 PASS**, tam analiz
0 bulgu ve **881 dosyada sıfır biçim farkı**. Yeni CI hedefi 4 native +
8 uygulama = **12 E2E**; Linux'a özel testler ve yeni Android yolculuğu
gerçek CI sonucu gelmeden kabul edilmiş sayılmaz.
[Sekizinci yolculuk](core-resource-admin-android-journey-2026-09-06.md).
Core metadata mutasyon API'si `8e00548` yerel dalında **87 odaklı / 656 ilgili
Client ve 40 Server testi**, temiz analiz ve bağımsız inceleme ile doğrulandı.
Bu API'nin PIN korumalı oluşturma, ad/sıra değiştirme ve kayıt silme UI'si
`68e77b8` yerel diliminde **431 ilgili test**, temiz analiz, 12 tablet/DeX
boyut-tema-dil kontrolü ve bağımsız inceleme ile geçti. Yeni Android E2E
yolculuğu birleştirildi; bu UI henüz APK 99'da değildir. ACL editörü ve gerçek cihaz komutları
ayrı açık işlerdir. Kuyrukta kabul sayısı bu alt dilimler için artırılmadı.

**Kaynak erişimi API'si yerel olarak doğrulandı:** `a65691d`, gerçek Core
grant/no-op/revoke yanıtlarını Client'a bağlar; **53 odaklı / 709 ilgili Client,
131 ilgili Server PASS**, yeni 108 satırın tamamı testte, bağımsız inceleme
temiz. Kullanıcı seçimi ve ACL yönetim ekranı ayrı dalda geliştiriliyor.
[Sözleşme kanıtı](core-home-resource-grants-contract-2026-09-06.md).

**S06.3d depolama alternatifi:** Core'a ait yönetilen volume önerisi saf plan
olarak eklendi: **32 yeni / 182 ilgili PASS**, modülde dal dahil %100 kapsam,
bağımsız kaynak incelemesi temiz. Henüz Engine'e veya HTTP kurulum yoluna
bağlanmadı; `installAvailable=false` sürer. Sahiplik gözlemi, kalıcı journal,
UID/bootstrap ve gerçek kurulum etkileri açıktır.
[Değerlendirme](managed-volume-storage-assessment-2026-09-06.md) ·
[Uygulama kanıtı](managed-volume-proposal-implementation-2026-09-06.md).

**Volume gözlemi sonraki yerel birleşime alındı:** `4baa55a`, yedi managed
hedefi tam plan/kimlik/etiketlerle eşleştiren katı Engine yanıt denetimini
ekler. **95 odaklı / 282 ilgili test**, 124 satır ve 24 dalda %100 kapsam;
bağımsız inceleme temiz. Host dizini açılmaz ve gözlem kurulum yetkisi sayılmaz.
Kalıcı volume journal'ı, gerçek bootstrap ve Engine işlem bağlantısı açık.
[Gözlem kanıtı](managed-volume-observation-implementation-2026-09-06.md).

**Sonraki bağımsız volume journal paketi hazır:** `codex/managed-volume-journal`
dalı `f9a3faa` checkpoint'inde **54 odaklı / 273 ilgili PASS** ve bağımsız
inceleme ile donduruldu; yeni modül 139 satır ve 8 dalda %100 kapsamda.
Bu dal yukarıdaki tam Server koşusuna veya mevcut yayına dahil değil.
Yalnız gözlem geçmişini saklar; Engine/bootstrap ve kurulum yetkisi açık.

**S08.4 kabul incelemesi tamamlandı:** üç kabul maddesi ve 22 kayıt sınıfı
kaynak/test kanıtlarıyla eşleştirildi; yeni somut P1/P2 bulunmadı. Yeni paketin
kendi CI kapısı geçince bu adım kapanabilir. Restore S08.5 ve typed
adaptör/cache S08.7–9 ayrı kalır.
[İnceleme](client-boundary-acceptance-review-2026-09-06.md).

S08.4'ün önceki 31 ayrıntılı kanıt kaydı
[özgün kayıt arşivinde](client-boundary-evidence-archive-2026-09-06.json)
aynen korunur. Yürütme kuyruğu yerel test/inceleme özetlerini buraya bağlar;
başarılı ve başarısız CI kayıtları kuyrukta da kalır. Bu düzenleme kabul
sayılarını veya tarihsel test sonuçlarını değiştirmez.

**6 Eylül günlük depolama bakımı tamamlandı:** bir eski debug APK çıktısı,
**129.424.470 bayt** temizlendi. En yeni üç debug APK korundu; imzalı çıktılar
ve test raporları silinmedi. Sonraki envanter silinen kaydın yokluğunu ve
korunan üç kaydı doğruladı. GHCR paket izni olmadığından imaj temizliği yapılmadı.

**Önceki tam doğrulanmış yayın `8c3b60d` / APK 96: üç CI ve bağımsız APK kontrolü başarılı.**
Linux Server **2.916 testi atlamasız**, Flutter **2.989**, JVM **98** ve
**dört native + altı uygulama = 10 E2E** geçti. Güvenlik CI 207 testi ve
secret taramasını geçti. Yeni Core login/PIN/oda kopyası/remount/başka Core
akışı gerçek Android CI'da doğrulandı. 57 faz, altı temizlik; E2E komutu
322,195 saniye, 18 dakika sınırında 757,805 saniye pay var.
[Android 96](https://github.com/ersingundem/larenor/actions/runs/33995289219) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/33995289140) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33995288940).

AMD64/ARM64 Core medya **hazırlığı**/restart/iptal smoke'u ve anonim yayın
başarılı: `sha256:d3a2b48c07634be20c59b14e2a84b2b6f3e89e69c1094205f4e7f7be3355c027`.
Bu kontroller gerçek medya bileşeni veya ev kurulumu değildir.

[İmzalı APK 96 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33995289219/artifacts/9978185451)
tek tam indirmeyle Java 17 + sabit apksig 9.1.0 kullanılarak ayrıca doğrulandı:
`com.ersingundem.larenor`, sürüm kodu `100000096`, minSdk 26,
`debuggable=false`, kalıcı sertifika ve kaynak commit eşleşti. APK SHA-256:
`1017d1405d4127dbed241a4957826ab6660b4fc2185c33d57bb334e5dba2a5c8`.
Ev Server'ına koşullu Client yayını atlandı; ev/tablet kurulumu yapılmadı.

**Yeni birleşik teslim `27def3d`:** Arr/backup ve eski Core fixture düzeltmesi ana dalda.
`7f9a74f` üzerinde tam Client **3.421 PASS / 4:00**, tam analiz temiz,
845 dosyada biçim kontrolü sıfır değişiklik. Ardından eklenen tek fixture testi
ve genişletilen senaryo `27def3d` üzerinde **18 son destek testi**, dört dosyada
temiz analiz/biçim ile doğrulandı. Kaynak incelemesi temiz. Yeni Android/Core
CI üstteki Android 98 kaydında geçti; bağımsız imzalı APK 98 kontrolü de geçti.
[Fixture düzeltmesi](core-resource-fixture-compat-2026-09-06.md).

**Kaynak ekranı paketi `808938e`:** diafon/film gecesi kaynak sınırı, Core'un
salt okunur oda/kaynak ekranı ve yeni yedinci Android yolculuğu birleştirildi.
Birleşik yerel Client **3.115 testi 3:40 içinde geçti**; tam analiz sıfır
bulgu, 838 dosyada biçim kontrolü sıfır değişiklik. Gerçek Server ortak
kaynak sözleşmesi üç testi, kuyruk doğrulaması 24 testi geçti. Bu yeni
ekran/yolculuk APK 96'da yoktur; yeni CI ve imzalı APK kabulü ayrıca izlenecek.

**`20d92d7`: Core ve güvenlik geçti; Android 97 başarısız, APK üretilmedi.** [Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33997176904)
207 testi ve secret taramasını geçti. [Android 97](https://github.com/ersingundem/larenor/actions/runs/33997176965)
içindeki Server işi 2.919, Flutter 3.115, JVM 98 testi geçti.
E2E: dört native ve altı uygulama senaryosu geçti; eski scoped-layout senaryosu
son temizlikte dört reddedilen istek nedeniyle durdu. Yeni kaynak ekranının
yedinci uygulama senaryosu geçti. Eski admin test sunucusunda görünür ekranın
oda/kaynak GET desteği eksikti; `1f7c6b4` bu eski kullanıcı/rolü değiştirmeden
aynı kapsama ait boş liste yanıtını ekler. İstek/yetki/temizlik kontrolleri korunur.
Bu düzeltmenin Android 98 E2E kabulü geçti; imzalı APK 98 kontrolü de geçti.
[Core imajı](https://github.com/ersingundem/larenor/actions/runs/33997176958)
ilk denemesinde 2.918 PASS ve bir Unix test düzeneği kapanış zaman aşımı var.
İlk hata kaydı korunarak yalnız başarısız iş bir kez yeniden çalıştırıldı;
ikinci deneme **2.919 test ve imaj işlerinde başarılı**. İlgili dokuz intent-değişimi senaryosu
yerelde 20 ayrı koşuda, toplam 180 çalıştırmada geçti. Bu tekrarlar ilk Linux
hatasının sebebini kesinleştirmez veya onun yerine geçmez.

**Sıradaki birleşik paket `e4f0f15` ana dala alındı:** dört Arr bağlantısı
ve yedek sınırı **3.418 tam Client testi**, temiz analiz ve 845 dosyada sıfır
biçim değişikliğiyle doğrulandı. Bağımsız incelemeler temiz. Önceki yayının
eksik Android kapısı düzeltilirken Jellyseerr/Bazarr/Prowlarr, qBittorrent ve kişisel sağlık/fotoğraf
kayıtlarının sınırları ayrı dallarda ilerliyor. Bu paketler henüz CI kabulü almadı. Kişisel kayıt paketi `4eac0f6` 253 ilgili
test ve bağımsız incelemeyle sonraki birleşim için hazır; diğer iki pilotun
son UI/inceleme işleri devam ediyor.

<details>
<summary>Önceki tam doğrulanmış yayın: 394de0f / APK 95</summary>

**Önceki tam doğrulanmış yayın `394de0f` / APK 95: üç CI ve bağımsız APK kontrolü başarılı.** 2.792 Linux Server testi
atlamasız, 2.837 Flutter, 98 JVM, dört native + beş uygulama = dokuz E2E ve
207 araç testi geçti. Yeni gerçek Linux tam kök/proc/mount/descriptor fixture'ı
0,204 saniyede geçti. Android akışı 260,80 saniye; Gradle ağır derlemesi cihaz
başlatılmadan önce tamamlandı. İmzalı APK 95, Java 17 ve sabit apksig 9.1.0
ile ayrıca doğrulandı.
[Android](https://github.com/ersingundem/larenor/actions/runs/33991460336) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/33991460310) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33991460186).

AMD64/ARM64 Core medya hazırlığı/restart/iptal smoke'u ve anonim yayın
başarılı: `sha256:1dcc66fcc964d6f5d1ab6a1d0df653f43d21c7562bb5f19bd098815f89461642`.
Bu kontroller gerçek medya bileşeni veya ev kurulumu değildir.

[İmzalı APK 95 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33991460336/artifacts/9977060537):
`com.ersingundem.larenor`, sürüm kodu `100000095`, minSdk 26,
`debuggable=false`, kalıcı imza ve kaynak commit eşleşti. APK SHA-256:
`e12a90c81ff1b22ab1bf5dc1ca272dc6675de65dac2587cd311f594f6ce67be1`.
Ev Server'ına koşullu Client yayını atlandı; ev veya cihaz kurulumu yapılmadı.
İlk bağımsız indirme hazırlığı geçici dizin adı hatasıyla 0 bayt yazmadan durdu;
yol düzeltildikten sonra tek tam indirme ve kontrol başarılı oldu.

</details>

<details>
<summary>Önceki tam doğrulanmış yayın: 4b98680 / APK 94</summary>

**Son tam doğrulanmış yayın `4b98680` / APK 94:** üç CI ve bağımsız APK
kontrolü başarılı. **2.704 Linux Server testi atlamasız**, 2.815 Flutter,
98 JVM, **dört native + beş uygulama = dokuz E2E** ve 207 araç testi geçti.
[Android](https://github.com/ersingundem/larenor/actions/runs/33989941216) ·
[Server](https://github.com/ersingundem/larenor/actions/runs/33989941147) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33989940928).

Yeni Direct → Core → Direct yolculuğu eski HA bağlantısının kapanmasını ve
açık seçimden sonra yeni abonelik kurulmasını doğruladı. 48 faz, beş temizlik;
E2E komutu 242,584 saniye, 18 dakika sınırında 837,416 saniye pay var.
Emülatörden önce Gradle 331 saniye; cihaz açıkken 20,6/31,2 saniye.
Native odak geçti; önceki Quickstep hatası bu koşuda görülmedi.

AMD64/ARM64 Core restart, medya **hazırlığı** ve iptal smoke'u; anonim
commit/stable/index ve iki mimarinin kaynak/lisans kayıtları doğrulandı:
`sha256:8df10dcadb6f97db17eabbf41fc566c394b45a9b0161227f5107673a348bb19b`.
Gerçek medya bileşeni kurulumu bu smoke kapsamında değildir.

[İmzalı APK 94 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33989941216/artifacts/9976632723)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000094`, minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
APK SHA-256: `44d505607e282ff23bb24ffeb349dd12f5e71ea6533d5be6db65812f3a3f6bbf`.
Ev Server'ına koşullu Client yayını atlandı; ev/cihaz kurulumu yapılmadı.

</details>

- **S08.3 ev kaynak sınırı kabul edildi:** `10d3eb1` → `4ba7024`; açık, kalıcı doğrudan
  HA/Core seçimi ve bağımsız ev runtime'ı. Eski evin route/WS/callback'leri
  kapanır; hesap, PIN, tema ve güç ayarları ortak sahiplikte kalır. Core
  adaptörleri hazır olmadan eski yerel HA/medya verisi Core ekranına sızmaz.
  50 odaklı ve 1.093 ilgili test, %99,2 yeni modül satır kapsamı ve bağımsız
  inceleme geçti. Yeni beşinci uygulama akışıyla **dokuz E2E ve imzalı APK 94**
  `4b98680` kaynağında doğrulandı. [Uygulama kanıtı](client-home-session-scope-implementation-2026-09-05.md).
- **B5.1 dashboard:** `5cf7f30` → `8cc4665`; kartlarda Tab/Enter/Space,
  menü tuşu, tekil ekran okuyucu duyurusu ve görünür odak. Servis kartları
  gizli/eski oturumdan sayfa açamaz; termostat ok tuşlarıyla ayarlanır.
  343 dashboard ve 49 son delta testi, kapsam %88,1, scoped analiz ve
  bağımsız inceleme ve `4b98680` Android/yayın CI geçti. Genel B5.1 ve ayrı
  fiziksel TalkBack kabulü açık.
  [Uygulama kanıtı](tablet-dashboard-accessibility-implementation-2026-09-05.md).

Yeni birleşimde ilk yerel test başlangıcı eski üretilmiş çeviri dosyaları
nedeniyle durduruldu; kaynak üretimi ve çeviriler yenilendikten sonra tam
Client suite **2.815 testi 3:46 içinde geçti**. Bu hazırlık hatası başarı olarak sayılmaz.
Bu hazırlık düzeltmesinden sonra aynı kaynak uzak CI ve APK 94 kabulünü de geçti.

**Yeni CI ile doğrulanan paket (`14b7b62` → `394de0f`):** appdata tam kök gözlemi ve medya posterleri
birleşti. Medya kartları native klavye odağına sahip; 2× başlık satırı gerçek
ızgara genişliğine göre hesaplanıyor. 733 ilgili/22 son test, %92,5 ilgili
satır kapsamı, bağımsız kod ve açık/koyu gerçek-font görsel incelemesi geçti.
Tam Client **2.837 testi 4:04 içinde geçti**; analiz sıfır bulgu, 803 dosyada
biçim kontrolü sıfır değişiklik. Aynı üretim kaynakları yeni `394de0f`
Android CI içinde 2.837 Flutter, 98 JVM ve dokuz E2E ile doğrulandı. [Medya kanıtı](tablet-media-accessibility-implementation-2026-09-05.md).

**Sıradaki bağımlı çalışma:** S06.3d'de salt okunur native kimlik gözlemi
`3dde2f8` Linux CI ile doğrulandı. Onaylı tam appdata kökünün bütün parent/name/descriptor bağlarını tutan
resolver `32254ad` → `0d9e250` main içinde. 87 odaklı/573 ilgili test ve
bağımsız inceleme geçti. Tam Server **2.782 geçti, 10 Linux testi Mac'te
atlandı** (3:20,8). Ardından `394de0f` Linux CI **2.792 testi atlamasız**
geçti; yeni gerçek kök fixture'ı doğrulandı. Supervisor,
remap-disabled başlangıç kanıtı, issuer ve create/publish hâlâ açık.
[Native kimlik](native-identity-observation-implementation-2026-09-05.md) ·
[Kalan sıra](appdata-native-lease-plan-2026-09-05.md).
S08.3 kabulüyle başlangıç bağımlılığı açılan [kapsamlı düzen deposu ve açık taşıma](client-scoped-storage-plan-2026-09-05.md)
ilk dilimi `3018c57` → main `fd23a3f` içinde. Core/ev/kullanıcıya ayrı kayıt,
PIN korumalı önizleme ve seçili pasif oda adlarının kopyası eklendi.
93 son test, %96,9 ilgili satır kapsamı, bağımsız inceleme ve dört gerçek-font
görsel kontrolü geçti. `115dfa1` altıncı Android yolculuğu da birleşti;
`fd23a3f` üzerinde tam Client **2.914 test**, temiz analiz ve 814 dosyada
biçim kontrolü geçti. Bu altıncı Android yolculuğu `8c3b60d` ve APK 96 ile CI kabulü aldı.
[Diğer kayıtların envanteri](client-record-ownership-2026-09-06.md) çıkarıldı.

**S08.4 HA ve yedek sınırı ana dalda:** `d8edab5` ve `9b11195` → `7ed736b`.
Gerçek HA provider/store ve EnabledServices seed erişimi Direct kaynak
sahipliğine bağlı; Core veya eski callback sır okuma, kayıt veya HA transport
oluşturamaz. Yarım HA adres/token kaydı kalıcı bir işaretle durur; yalnız açık,
tam yeniden bağlantı veya silme bu belirsizliği kapatır. Böyle bir çift yeni
yedeğe/restore hazırlığına giremez; mevcut journal kurtarması çalışır ve işareti
silmez. Direct paketinde 53 son/482 ilgili test ve %99,5 satır kapsamı;
yedekte 40 son/143 ilgili test, repository %98,2 ve ekran %94,4; bağımsız
incelemeler ve analizler temiz. Toplamlar birbirine eklenmez. `7ed736b`
birleşik Client **2.989 testi 3:58 içinde geçti**; analiz sıfır bulgu,
820 dosyada biçim kontrolü sıfır değişiklik. Aynı dilimler `8c3b60d`
2.916 Linux, 10 E2E ve APK 96 ile de geçti. Bütün S08.4 kabulü açık.
[Direct kanıtı](direct-home-boundary-implementation-2026-09-06.md) ·
[Yedek kanıtı](ha-backup-boundary-implementation-2026-09-06.md).
**Diafon/film gecesi sınırı da `cc3db2` → main `cc0d89d` içinde:**
eski kaynak callback'leri kayıt yapamaz, kapı komutu veya film akışı
başlatamaz. 542 ilişkili test, %86,2 ilgili satır kapsamı, temiz analiz
ve bağımsız inceleme geçti. `808938e` birleşik Client 3.115 testi ve analizi
geçti; yeni CI kabulü açık.
[Kanıt](direct-home-routines-implementation-2026-09-06.md).
Sıradaki pilot ortak credential kayıt sınırıyla Sonarr/Radarr/Lidarr/Readarr
bağlantılarıdır; çok alanlı kayıt belirsizliği ve yedek kontrolleri birlikte
tamamlanmadan bu pilot birleştirilmeyecek.

**Paralel S08.6 ana dalda:** Kalıcı, şifreli oda/kaynak/hesap izin kayıtları ve
gerçek authenticated HTTP API `133786e` / belge `1b6b866` ile birleşti.
Üye yalnız izinli kayıtları görür; opak sayfa özeti gizli kayıt hareketlerini
açıklamaz. 124 odaklı test, dal dahil %95 kapsam, bağımsız inceleme ve tam
Server **2.906 PASS / Mac üzerinde 10 Linux skip** geçti. `8c3b60d` Linux CI **2.916 testi atlamasız** ve iki mimarili
imaj kapısını da geçti. Client salt okunur liste ekranı `codex/core-home-resource-list` üzerinde
`73dba35` → main `808938e` içinde. 82 odaklı/940 ilgili test,
%99,2 yeni feature satır kapsamı, 8 gerçek-font tablet kontrolü ve bağımsız
inceleme geçti; `808938e` birleşik Client 3.115 testi ve analizi geçti.
Yeni yedinci Android yolculuğu ve CI kabulü açık.
[Client kanıtı](core-home-resource-list-implementation-2026-09-06.md) ve
[yedinci Android yolculuğu](core-home-resources-android-journey-2026-09-06.md)
yeni teslim kapsamını ayırır. Yönetim ekranı, hane kişi profilleri, değişmez sağlayıcı bağları
ve gerçek cihaz komutları henüz tamamlanmış sayılmıyor.
[Uygulama ve kanıt](home-resource-registry-implementation-2026-09-06.md).

**S08 kabul sırası netleştirildi:** Mevcut kayıt kapsamı S08.4, restore/journal
S08.5, kimlik/yetki S08.6; gerçek HA eşlemesi ve typed cache S08.7, medya
S08.8, altyapı S08.9. Böylece bir adım kendi sonraki adaptörünü bitiş önkoşulu
olarak beklemiyor. Kapsam ve 125 işlik kuyruk korunuyor; kabul sayısı 7/125.

**S08.9 Proxmox salt okunur pilotu ayrı dalda:** `codex/core-proxmox-adapter`
node/QEMU-LXC guest/storage özetini yönetici preview/onay binding'i ve Home
Resources read ACL'si üzerinden Core'a taşır. Beş saniyelik typed cache exact
Core/ev/kaynak/binding/servis/kullanıcı/oturum tuple'ına bağlıdır; endpoint,
credential, revizyon, ACL veya oturum değişince geç yanıt yayınlanmaz. Bu paket
güç/yapılandırma komutu eklemez ve gerçek Proxmox'a bağlanmadı. Mevcut Android
Direct Proxmox yolu, Core-backed Client geçişi ve fiziksel tablet kabulüne kadar
geçici olarak açıktır. Bu yalnız pilot kanıtıdır; S08.9 ve seçilen özellik kabul
sayaçları değişmedi. [Sınır ve API](core-proxmox-resource-pilot-2026-09-10.md).

**Yarım çalışmaları kaybetmeden devam:** önce çalışma kopyaları, dallar,
agent ve CI durumları incelenir; aynı iş yeniden başlatılmaz. Tamamlanan
RED/GREEN checkpoint'leri git geçmişinde tutulur; ana dala birleşme uzak CI
kabulü değildir. Geçici çalışma kopyaları kalıcı arşiv yerine geçmez.

| İş | Dal / çalışma kopyası | Durum |
| --- | --- | --- |
| B5.1 tablet ayarları | `codex/tablet-settings-accessibility` | `ba884f6` main içinde; yeni `3dde2f8` sekiz E2E ve Android CI geçti. |
| B5.1 medya posterleri | `codex/tablet-media-accessibility` · `/private/tmp/larenor-tablet-media-accessibility` | `cb792c0` → `14b7b62` main içinde; 733 ilgili/22 son test ve bağımsız görsel inceleme geçti. Tam Client 2.837 test/analiz ve `394de0f` dokuz E2E geçti; bağımsız imzalı APK 95 doğrulandı. |
| B5.1 dashboard | `codex/tablet-dashboard-accessibility` · `/private/tmp/larenor-tablet-dashboard-accessibility` | `5cf7f30` birleşti; `4b98680` tam Android CI ve APK 94 kabulü geçti. |
| S06.3e ağ journal köprüsü | `codex/network-effect-bridge` | `6a00168` main içinde; `9138e61` Server/güvenlik CI ile yazılım kabulü tamamlandı. |
| S08.4 kaynaklı düzen | `codex/client-scoped-layout` ve `codex/scoped-layout-e2e` | `3018c57` ve `115dfa1` ana dalda; 93 son ve 2.914 tam Client testi/analiz geçti. Altıncı Android yolculuğu ve APK 96 `8c3b60d` ile doğrulandı. |
| S08.4 HA ve yedek sınırı | `codex/direct-home-boundary` ve `codex/ha-backup-boundary` | `d8edab5` ve `9b11195` → main `7ed736b`; 53/40 son test ve bağımsız incelemeler temiz. `8c3b60d` 2.989 Flutter/10 E2E ve bağımsız APK 96 kontrolü geçti. |
| S08.4 diafon/film gecesi | `codex/direct-home-routines` | `cc3db2` → main `cc0d89d`; 542 test ve inceleme geçti. `808938e` birleşik Client 3.115 test/analiz geçti; yeni CI açık. |
| S08.4 Arr bağlantıları ve yedek sınırı | `codex/direct-arr-credentials` ve `codex/direct-credential-backup` | 0298c5a ve 6426d55 birleştirildi; 192 odaklı/547 ilgili Arr ve 245 ilgili backup testi, bağımsız incelemeler temiz. e4f0f15 birleşik 3.418 test/analiz geçti; yeni Android düzeltmesiyle CI açık. |
| S08.6 Core kaynak listesi | `codex/core-home-resource-list` ve `codex/core-home-resources-e2e` | `73dba35` ve `c0b765c` → main `808938e`; 82 odaklı/940 ilgili test, tablet QA ve bağımsız inceleme geçti. Birleşik Client 3.115 test/analiz temiz; yedinci Android yolculuğu ve yeni CI açık. |
| S08.6 Core kaynak/yetki kaydı | `codex/home-resource-registry` | `133786e` / `1b6b866` ana dalda; tam Server 2.906 PASS/10 Mac skip, 124 odaklı test, %95 dal kapsamı ve inceleme temiz. `8c3b60d` Linux 2.916/iki mimari geçti. Yeni Client liste/bütün yönetim kabulü açık. |
| S08.7 seçili HA switch durumu ve komutu | `codex/core-ha-switch-adapter`, `codex/core-ha-switch-client`, `codex/core-ha-command` | İlk durum dilimi main `e11eb57`; kalıcı idempotent komut/makbuz davranışı `409ffc8`, kanıt `0949e3b` → main `914e1e7`. Tam Server 3.748 PASS/12 Mac skip; ilgili 222 Server ve 124 Client PASS, Core HA Client kapsamı %95,52; bağımsız son inceleme temiz. Exact-source CI, Direct aktarımı, geniş HA kapsamı ve fiziksel kabul açık. |
| S08.3 Client ev runtime'ı | `codex/client-home-session-scope` · `/private/tmp/larenor-client-home-session-scope` | `10d3eb1` birleşti; `4b98680` dokuz E2E ve imzalı APK 94 ile S08.3 kabul edildi. |
| S06.3d appdata tam kök gözlemi | `codex/native-appdata-root-observation` · `/private/tmp/larenor-native-appdata-root-observation` | `32254ad` → `0d9e250` main içinde; `394de0f` gerçek Linux 2.792 test/0 skip ve iki mimarili hazırlık smoke geçti. Salt okunur gözlem yazma yetkisi değildir. |

Ağ yazılımının gerçek Engine/iki mimarili kaynak kabulü **S06.3f** içindedir.
Production dispatcher/host grant, appdata oluşturma ve medya kurulumu açık;
`installAvailable=false` değişmedi.

<details>
<summary>Önceki doğrulanmış yayın: 3dde2f8 / APK 93</summary>

**Önceki tam doğrulanmış yayın `3dde2f8` / APK 93:** Server, Android ve güvenlik başarılı.
Linux **2.704 test atlamasız**, 2.739 Flutter, 98 JVM, dört native + dört
uygulama E2E senaryosu ve 207 araç testi geçti. İndirilen APK 93, Java 17 +
sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika, `100000093`,
minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
[İmzalı APK 93 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33988283337/artifacts/9976135162).
APK SHA-256: `b9582694525493255641ab172aa90630d114ed88218a821accff5556f3695065`.
[Server](https://github.com/ersingundem/larenor/actions/runs/33988283387) ·
[Android](https://github.com/ersingundem/larenor/actions/runs/33988283337) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33988283178).

AMD64/ARM64 Core restart, medya **hazırlığı** ve iptal smoke'u geçti; anonim
commit/stable/index ve iki mimarinin kaynak/lisans kayıtları doğrulandı:
`sha256:e77b7a11907ac009d8000ec374fcb94745614602331c9da307d41ca97fb895d6`.
Gerçek medya bileşeni kurulumu bu smoke kapsamında değildir; ev Server'ına
koşullu Client yayını atlandı, ev/cihaz kurulumu yapılmadı.

**Emülatör hazırlığı gerçek CI'da doğrulandı:** ağır derleme emülatörden önce
403 saniyede tamamlandı. Emülatör açıkken ilk Gradle derlemesi önceki koşudaki
363,9 saniyeden 23,9 saniyeye indi; ikinci derleme 36,0 saniye. Test komutu
231,793 saniye sürdü; 42 aşama ve dört temizlik tamamlandı. Native odak testi
geçti. Bu tek koşu, önceki Quickstep ANR'nin kesin kök nedenini veya kalıcı
çözümünü kanıtlamaz; toplam CI aynı oranda hızlanmış değildir.
[Ölçüm ve sınırlar](android-e2e-precompile-2026-09-05.md).

</details>

<details>
<summary>Önceki koşu: 9138e61 Core kabulü, Android 92 hatası</summary>

Linux 2.566 test atlamasız, iki mimarili Core hazırlık/restart/iptal ve
güvenlik kontrolleri geçti; bu backend kanıtıyla **S06.3e** kabul edildi.
[Server](https://github.com/ersingundem/larenor/actions/runs/33986835291) ·
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33986835178).
İmaj `sha256:7902dc0fcf299c0b2b7e598943a6293c8af6e5e60efd0e13f1f27ac28216d805`.

[Android 92](https://github.com/ersingundem/larenor/actions/runs/33986835301)
2.739 Flutter, 98 JVM ve dört uygulama akışını geçti. Quickstep ANR nedeniyle
native odak testi başarısız oldu: E2E 7/8, imzalı APK 92 üretilmedi.
QEMU/adb canlı, ekran uyanık ve kilitsizdi; OOM veya emülatör çökmesi
kanıtlanmadı. 673,224 saniye, 42 aşama ve dört temizlik kaydedildi.

</details>

<details>
<summary>Önceki doğrulanmış yayın: 19dbcbe / APK 91</summary>

**Önceki tam uzak yayın `19dbcbe`:**
[Server](https://github.com/ersingundem/larenor/actions/runs/33985459924),
[Android](https://github.com/ersingundem/larenor/actions/runs/33985459959) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33985459857)
**imzalı APK 91 dahil başarılı**. **2.298 Linux Server testi atlamasız**;
2.701 Flutter, 98 JVM, sekiz emülatör senaryosu ve 202 araç testi geçti.
Linux'un unread Unix stream reset davranışı ve iki iptal/kapanış varyantı
ayrıca geçti; önceki `54a677b` hatası kapandı. Emülatör 9:34,4 ile 18 dakika
sınırında; 42 aşama ve dört tamamlanmış temizlik var.

AMD64/ARM64 Core restart/medya hazırlığı/iptal smoke'u ve anonim
commit/stable/index/child/sourceRevision doğrulaması geçti:
`sha256:9867d551fb10cf141bc513569eab523162485eb04caaa181abd06249a840b8cd`.
[İmzalı APK 91 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33985459959/artifacts/9975280844)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000091`, minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
APK SHA-256: `caf77a39de2586b1250c3dcf1ebe3cbd2a3b66f4a73f3b1342b28e7319ccc498`.
Ev Server'ına koşullu Client yayını atlandı; ev/cihaz kurulumu yapılmadı.
Bu kanıt sonraki kaynak değişikliklerini kapsamaz.


</details>

<details>
<summary>Önceki doğrulanmış yayın: 1408e80 / APK 89</summary>

**Son tam uzak yayın `1408e80`:**
[Server CI](https://github.com/ersingundem/larenor/actions/runs/33982544738),
[Android CI](https://github.com/ersingundem/larenor/actions/runs/33982544696) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33982544575)
**imzalı APK 89 dahil başarılı**. 2.092 Linux Server testi atlamasız;
2.678 Flutter, 98 JVM, sekiz emülatör senaryosu ve 202 araç testi geçti.
Üç gerçek Linux peer/mount vakası ayrıca doğrulandı. Emülatör akışı 9:59,2
ile 18 dakika sınırında; 42 aşama işareti ve dört tamamlanmış temizlik var.

AMD64/ARM64 Core imajları restart/medya hazırlığı/iptal kontrolünü geçti;
anonim commit/stable/index ve iki mimarinin sourceRevision değerleri doğrulandı:
`sha256:2c639e795687b28290de3f83bd3e85dad658812e79f03e094863aa86a0e27523`.
[İmzalı APK 89 ve metadata](https://github.com/ersingundem/larenor/actions/runs/33982544696/artifacts/9974481883)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000089`, minSdk 26, `debuggable=false`, kaynak commit ve metadata eşleşti.
APK SHA-256: `6829fd342d629931b2ef60ab7911af0d445340642d2b7cee1eb96023ca363243`.
Ev Server’ına koşullu Client yayını atlandı; cihaz/Server kurulumu yapılmadı.

</details>

<details>
<summary>Önceki doğrulanmış yayın: fc632b6 / APK 88</summary>

[Server](https://github.com/ersingundem/larenor/actions/runs/33981106713),
[Android](https://github.com/ersingundem/larenor/actions/runs/33981106645) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33981106554)
imzalı APK 88 dahil başarılı. 1.890 Linux Server testi atlamasız; 2.659
Flutter, 98 JVM ve sekiz emülatör senaryosu geçti. Emülatör akışı 10:04,7;
42 aşama/temizlik işareti doğrulandı. Bu paket S06.3c ve S08.1 kabulüdür.
İki mimarili imaj anonim doğrulandı:
`sha256:00902e8b6142d546a9493e7db4a2b55a8fa166cbd44f9a4932894ae9fd5c4c22`.
[APK 88](https://github.com/ersingundem/larenor/actions/runs/33981106645/artifacts/9974067173)
Java 17 + sabit apksig ile ayrıca doğrulandı; `100000088`, doğru sertifika ve
`debuggable=false`. APK SHA-256:
`757b63032d51b3289f8ecb9d189f451bf777828e1867273d75e13eb485d75a47`.
Ev Server'ına yayın atlandı; ev kurulumu yok.

</details>

<details>
<summary>Önceki doğrulanmış yayın: 483ec13 / APK 87</summary>

[Server](https://github.com/ersingundem/larenor/actions/runs/33979199140),
[Android](https://github.com/ersingundem/larenor/actions/runs/33979199144) ve
[Güvenlik](https://github.com/ersingundem/larenor/actions/runs/33979199030)
1.736 Linux Server, 2.625 Flutter, 98 JVM, sekiz E2E ve 202 araç testini geçti.
İki mimarili imaj anonim doğrulandı:
`sha256:7b368f5e5575746de203e88c96a3c64fb99527032b6806dce538f816c73ced61`.
[APK 87](https://github.com/ersingundem/larenor/actions/runs/33979199144/artifacts/9973530086)
Java 17 + sabit apksig 9.1.0 ile ayrıca doğrulandı: doğru paket/sertifika,
`100000087`, minSdk 26, `debuggable=false` ve kaynak commit eşleşti.
APK SHA-256: `1d642a628da571fbb5f4e0d453ac6c6bf94c2d69b6b5aa2109926df0730f3a76`.
Bu önceki kanıt daha yeni Client bağlamı veya imaj/journal köprüsünü kapsamaz.

</details>

<details>
<summary>Önceki temel kabul ve CI düzeltmeleri: 62b2054 ve öncesi</summary>

**S06 dilim 2 tamamlandı:** [birleşik medya gereksinim kontrolü](media-inspections-implementation-2026-09-05.md),
şifreli kalıcı sonuç/geçmiş/iptal, Android yönetim ekranı, toplam disk bütçesi ve
ayrı daemon bağlamı gözlemleri uygulandı. Bağımsız inceleme bulguları
regresyonlarla düzeltildi. İlk dilimdeki altı bileşenli hazırlık korunur;
`prepared` kurulum, `succeeded` ise bütün gereksinimler geçti demek değildir.

**Doğrulanan kod ve yayın: `62b2054`.**
[Security](https://github.com/ersingundem/larenor/actions/runs/33976443262),
[Server](https://github.com/ersingundem/larenor/actions/runs/33976443375) ve
[Android](https://github.com/ersingundem/larenor/actions/runs/33976443371)
CI'larının tamamı **imzalı APK teslimi dahil başarılı**.

- **1.516 Linux Server testi, sıfır atlama**; gerçek Linux socket/peer-context
  testi JUnit raporunda geçti. Yerelde 1.515 geçti, bir Linux testi Mac'te atlandı.
- **2.625 Flutter, 98 JVM/Robolectric ve 8 cihaz E2E senaryosu** geçti.
  Emulator 36.1.9.0/build 13823996; dört platform + dört uygulama senaryosu,
  42/42 aşama/temizlik işareti. Script yaklaşık 8:39 ile 18 dakika sınırında;
  bütün action yaklaşık 9:50. Analiz temiz; 178 araç testi geçti.
- **AMD64 ve ARM64 imajları** gerçek container restart/medya hazırlığı/iptal,
  APK doğrulayıcı ve kapalı inspection yeteneği kontrollerini geçti. Anonim
  erişimle commit ve `stable` için aynı imaj indeksi doğrulandı:
  `sha256:7ff0e5ef2322ad1711be7b9bcd6d79119695a2b9aa6718ce40e224b007875e70`.
- [**İmzalı APK 86 ve metadata**](https://github.com/ersingundem/larenor/actions/runs/33976443371/artifacts/9972729514)
  indirildi ve Java 17 + hash ile sabitlenmiş resmi apksig 9.1.0 ile ayrıca
  doğrulandı. Paket `com.ersingundem.larenor`, sürüm `100000086`, minSdk 26,
  doğru sertifika ve `debuggable=false`; kaynak commit ve APK SHA-256 eşleşti:
  `f5fa27b755331d8389985f4aa53ac8ef7b58f0e2f5de2615db06d849b91f70dc`.

Ev Server'ı henüz yapılandırılmadığından koşullu Client yayın adımı atlandı.
Ev cihazına veya sunucusuna kurulum yapılmadı. Medya motorlarını kurma,
otomatik eşleştirme ve gerçek HomePod oynatma kabulü hâlâ açık.

Bu sonuçları kaydeden son değişiklikler belgeler ve bir kaynak sürümü
alıntısının docstring düzeltmesidir; çalıştırılabilir Python AST'si aynı,
Client/test/workflow davranışı değişmedi. APK/imaj ve CI kanıtının kaynak
commit'i **`62b2054`** olarak kalır.

**Devam eden teslim:** [S06 dilim 3 — sahiplikli kaynak hazırlığı](media-resource-preparation-plan-2026-09-05.md).
Kaynak planı/journal → sabit digest ile imaj → sahiplikli appdata → özel kontrol
ağı → yarım işlem kurtarma/iki mimarili kabul sırası ayrıntılandırıldı.
Saf plan/journal ve imaj taşıması yerel testlerden geçti; bütün dilimin kabulü
henüz tamamlanmadı ve kurulum yetkisi açılmadı.

**CI hazırlığı düzeltmesi:** `ce1ce38` E2E'si uygulama senaryoları başlamadan
uyanık kalma ayarını doğrulayamadığı için durmuştu. `16dda6b` RED → `4e05b66`
GREEN ile yalnız seçilmiş QEMU emülatöründe toplam 10 saniye/en fazla beş
uygula-oku denemesi eklendi. Tam `7` veya `15` dışındaki kalıcı değer, ADB
hatası, taşan çıktı ve süre aşımı başarısız kalır; 21 regresyon geçti.
`19b14aa` gerçek koşusunda önkoşul ilk denemede doğrulandı ve bütün sekiz E2E
senaryosu geçti. Önceki hatanın kesin kök nedeni bu koşudan çıkarılmaz.

Önceki `5331f22` commit'inin Android/analiz/güvenlik CI çalışmaları artifact
depolama kotasına takıldı; taramalar bulgu üretmedi. Bu pakette rapor yükleme
hatası açık uyarıyla ayrıldı, güvenlik taramalarının artifact bağımlılığı
kaldırıldı. Asıl test/tarama hataları ve imzalı APK teslim hataları hâlâ engelleyicidir.

</details>

## Önceki çalışma görünümü (arşiv)

| İş | Durum | Tamamlanma ölçütü |
| --- | --- | --- |
| S05 hizmet yönetimi ve denetimi | Client admin ekranı, şifreli Server kayıtları ve 17 servis türünün kontrol yolu uygulandı | `19b14aa` Server/Güvenlik/Android ve imzalı APK teslimi geçti; gerçek servis kabulü ayrı |
| S06 birleşik medya hazırlığı/kontrolü | İlk iki dilim: hazırlık, toplam disk ve daemon bağlamı gözlemi, şifreli kontrol geçmişi/iptal ve Client akışı uygulandı | `62b2054` bütün CI ve imzalı APK geçti. Kaynak hazırlığı → kurulum adımları → özel bootstrap → kurtarma açık; port/alıcı ağı henüz `unknown` |
| B3 kalıcı Core/ev bağlamı | Korumalı kimlik API'si ve S08.1 atomik Client oturumu kabul edildi; S08.2 uyumluluk kod/testi hazır | S08.1 `fc632b6` tam CI; S08.2 kendi CI'ını bekliyor. Global provider/route/cache sınırı, merkezi adaptörler ve kaynak yetkileri açık |
| Gerçek Server imajı doğrulaması | `1408e80` AMD64/ARM64 Core restart/medya hazırlığı/iptal kontrolünü geçti ve yayımlandı | Anonim index ve kaynak kimliği doğrulandı; gerçek ev kurulumu ve medya motorlarının kurulması ayrı |
| Seçilen 63 özelliğin bağımlılık planı | İlk 60 seçim ve bağımsız VNC/RDP/SSH kaydedildi; 11 grup ve mevcut temel kapıları | Yeni özellik kabulü 0/63; SSH/tünel temeli → RDP → VNC, Proxmox veya medya kurulumu zorunlu değil |

**Son kapsam kararı:** Medya ve Music Assistant için ayrı uygulama kurulumu veya
elle API bağlantısı yapılmayacak. Bileşenler Larenor Server'a dahil olacak;
Client yalnız Larenor hesabı/API'si ve kullanıcı ayarlarını sunacak. Özel
bootstrap ve otomatik eşleştirme temeli S06.5 ile kabul edildi; birleşik dağıtım,
güncelleme ve geri yükleme S07–S09'da sürüyor.
[Güncel bütünleşik medya planı](integrated-media-stack.md).

**Platform anlatımı:** Larenor Client tablet öncelikli Android uygulamasıdır.
DeX ayrı bir uygulama değil; aynı uygulamanın değişken pencere ve harici ekran
desteğidir. README, mimari belgeleri ve GitHub açıklaması buna göre güncellendi.

## Backend, Music Assistant ve HomePod: önceki durum notu

| Özellik | Çalıştığı yer / mevcut durum | Eksik adım |
| --- | --- | --- |
| Hesap, parola, oturum, rol, kullanıcı yönetimi | Larenor Server API ve veritabanında uygulandı | Gerçek sunucuya manuel kurulum |
| Kasa ve güncelleme sürümleri | Server'da şifreli kasa ve sürüm API'leri; Client geri yükleme/güncelleme akışları mevcut | Gerçek imzalı Client yükseltmesi ve yeniden kurulum kabulü |
| Entegrasyon bağlantı kayıtları | S05 şifreli Server kaydı, Client admin ekranı ve 17 türün kontrol yolu uygulandı | Yerel/uzak testler geçti; gerçek servis kabulü ve S08 adaptör taşıması |
| Gereksinim kontrolü ve iş geçmişi | Kalıcı şifreli işler, Linux işçisi, Docker API/platform kontrolü, private bootstrap ve doğrulanmış sonuç/iptal/kurtarma zinciri uygulandı | S07 tek dağıtım paketi |
| Birleşik medya hazırlığı/kontrolü | Altı bileşen planı, kalıcı kontrol, sahiplikli kaynaklar, private bootstrap, authenticated readback ve ortak secret-free kurtarma görünümü; Client geçmiş/iptal | S07 tek paket; fiziksel port/alıcı ağı MANUAL kapısında |
| Core ve ev kimliği | Server'da kalıcı, anahtarla doğrulanan kimlikler; korumalı API ve Client sözleşme okuyucusu | Client oturum/cache ve kaynak kimliklerine bağlama; çoklu ev/federasyon henüz yok |
| HA, medya ve ağ komutları | Mevcut kontrollerin çoğu hâlâ Client adaptörlerinde | S08 ile gerçek veri ve komut akışlarını Server'a taşıma; yalnızca token saklamak bu taşıma sayılmaz |
| Music Assistant | Yönetilen 2.10.4 motoru; private admin/token bootstrap, provider/player keşfi, kuyruk/oynatma readback ve restart iki mimaride kabul edildi. Client ayrı MA URL/tokenı istemiyor | S07 tek dağıtım ve S09 kurulum/güncelleme/geri yükleme kabulü |
| HomePod / AirPlay | Music Assistant player keşfi, revision-bound komut ve authenticated sonuç zinciri yazılım testleriyle hazır | Gerçek sağlayıcı oturumu, aynı ağda HomePod keşfi, ses/grup/yeniden bağlanma MANUAL kabulü |

**Music Assistant'ın yönetilen Core yazılım zinciri tamamlandı; birleşik Larenor
Server dağıtımı henüz tamamlanmadı.** `deploy/larenor-server/compose.yaml` ve
Core katalog/runtime yolları sabit 2.10.4 motorunu aynı ürün kapsamında yönetir;
S07 bütün bileşenleri tek kurulum ve ayar yüzeyinde birleştirecek. Ayrıntı:
[S06.5 kabulü](s06-5-bootstrap-acceptance-2026-09-20.md) ve
[Music Assistant kurulum planı](music-assistant-deployment.md).
HomePod için upstream [AirPlay desteği](https://www.music-assistant.io/player-support/airplay/)
mevcuttur; Larenor üzerinden gerçek cihaz uyumluluğu henüz doğrulanmadı.

## Uygulananlar

“Uygulandı” kod ve belirtilen test kapsamını anlatır. Gerçek cihaz gerektiren
kabul işleri aşağıda ayrıca tutulur.

| Alan | Uygulanan kapsam |
| --- | --- |
| Ortak kullanım | Gezinme/arama, oda ve kart düzenleme, Bugün, enerji/bakım, bağlantı ve işlem sonucu ayrımı |
| Medya ve ağ | Ortak medya aşamaları, film gecesi rutinleri, Keenetic ölçüm kartları, Jellyfin/HA üzerinden yetenek kontrollü oynatma hedefleri |
| Tablet ve kiosk temeli | Değişken pencere/DeX düzeni, PIN ve özel sağlık görünümü, WebPanel kaynak/zoom ayarları, yönetilen görev kilidi, yerel fotoğraflı ortam ekranı ve haftalık program |
| Server hesapları | API ve veritabanı, ilk parola değişimi, dönen oturumlar, yönetici yetkileri, kullanıcı/oturum/denetim API'leri |
| Yapılandırma kalıcılığı | Şifreli yerel yedek; Server hesabıyla kasa önizleme, seçili bağlantı bilgilerini kaydetme ve yeniden kurulumdan sonra geri yükleme akışı |
| Client yönetici ekranları | Hesap, kullanıcı/rol, geçici parola, oturumlar ve denetim; son yöneticiyi koruma ve geçersiz kalan onayları kapatma |
| Merkezi hizmet bağlantıları | 17 tür için şifreli kayıt, ekle/düzenle/unut/kontrol; hizmete uygun giriş alanları. HA, medya ve ağ komutlarının tamamının Server'a taşındığı anlamına gelmez |
| Güncelleme altyapısı | APK paket/imza/hash/sürüm doğrulaması, sürüm API'leri, indirme ve Android kurucusuna geçiş; ayrı yayın kimliğiyle koşullu CI teslimi |
| Otomatik güncelleme uyarısı | Ön planda açılış/dönüş ve 15 dakika aralıklı kontrol; oturumluk kapatma, PIN korumalı bağlantı, hesap/rota/arka plan sınırları. İlgili 92 test geçti |
| Server Docker/CI kodu | Sabitlenmiş bağımlılıklar ve imza aracı, root olmayan süreç, ayrı veri/anahtar depoları; iki mimari ve gerçek APK imza kontrolü geçti. Yeniden başlatma testi de geçti ve ortak imaj yayımlandı; anonim manifest indirmesi doğrulandı |
| Server ekran tasarımı | Altı gerçek-widget önizlemesi incelendi; admin seçili sekmesi belirginleştirildi; test matrisi ve README'ye görseller eklendi |
| Bağımsız kod incelemesi | Server başlatma/kaynak/lisans/sürüm sözleşmeleri, Client güncelleme uyarısı ve Docker/CI akışında uygulanabilir ek bulgu çıkmadı; gerçek imaj çalışması yerine geçmez |
| Sunucu bileşenleri önizlemesi | Altı sabitlenmiş katalog kaydı, yönetici/oturum/katalog revizyonuna bağlı şifreli ve süreli önizlemeler; Client gereksinim ekranı. Kurulum düğmesi veya çalışan kurulum API'si yok |
| Kalıcı gereksinim işleri | Yönetici oluşturma/geçmiş/olay/iptal API'leri, şifreli plan/sonuç, belirsiz isteği aynı kimlikle kurtarma, restart ve güncel yetki denetimi. `succeeded` inceleme tamamlandı demektir; bütün kontrollerin geçtiği veya kurulum yapıldığı anlamına gelmez |
| Birleşik medya hazırlığı | Altı sabitlenmiş bileşen için tek kalıcı plan ve toplam istenen kaynak bütçesi; yönetici oluşturma/geçmiş/iptal, restart ve idempotence. Katalog değişse de geçmiş okunur; `installAvailable=false`. Jellyfin ortak kütüphaneyi yalnız salt okunur kullanır |
| Birleşik medya kontrolü | Toplam disk bütçesi, daemon mount/network/root gözlemleri, şifreli kalıcı kontrol işi ve tablet yönetimi; sahiplikli kaynak hazırlığı ile private servis bootstrap'ı ayrı doğrulanır |
| Dahili salt okunur işçi | Aynı Server paketindeki `larenor-preflight-worker`, Linux UID doğrulamalı Unix IPC; toplam kapasite/platform, Docker GET `/version` ve açık v3 politikasıyla socket/process bağlamı. Mutasyon ayrı retained installation worker yetkisine bağlıdır |
| Dar kurulum yürütme kapısı | Güncel actor/session/Core/ev/preparation/inspection/catalog kapıları; Jellyfin, qBittorrent, Arr, Seerr ve Music Assistant için journal-bound private bootstrap, authenticated readback, restart ve belirsiz sonuç ayrımı. S06.5 native kabul edildi; ürün kurulumu S07/S09 tamamlanana kadar `installAvailable=false` |
| Kalıcı Core/ev bağlamı | `/api/v1/context`, atomik şema 1→2→3 geçişi, HMAC doğrulaması; aynı 27 JSON örneğiyle Server ve Client okuyucu. Client oturum/cache bağlama henüz yok |
| Düzenli GitHub temizliği | Geliştirme/bakım takibi içinde günlük 03.15 sonrası kontrol ve testli araç; en yeni üç debug APK, bütün imzalı APK ve raporlar korunur. İlk koşumda beş eski debug APK (641.275.745 bayt) silindi; kalan 171 çıktı doğrulandı. GHCR izin ve manifest grafiği eksikliği nedeniyle silinmez |
| CI rapor kotası düzeltmesi | Test kanıtı yükleme hataları görünür uyarı üretir; Gitleaks/OSV taramaları artifact kotasına bağlı değildir. Gerçek tarama hatalarının engelleyici kaldığı test edildi |
| Lisans ve kaynak | AGPL-3.0-only, üçüncü taraf bildirimleri, uygulama içi lisans ekranı ve Server kaynak/lisans API'si |
| Geliştirme becerileri | İstenen frontend/CI seçkisinden 27 beceri kuruldu; 81 dosyanın kaynağı ve hash'i kaydedildi. Kurulum uygulama özelliği sayılmaz |

Son yerel doğrulamada **2.625 Flutter, 1.515 Server ve 178 araç testi** geçti.
Gerçek Linux peer-context testi macOS'ta atlandı; Linux CI'da 1.516 testin tamamı atlamasız geçti.
Server koşumunda gerçek Java/apksig kullanıldı. Workflow `actionlint` ve diff
kontrolü ve tam Flutter analizi temiz. Bağımsız incelemede bulunan
iş geçmişini belleğe topluca alma, hatalı worker ortam değerlerini güvenle
reddetme ve socket başlatma hatasında yalnız kendi inode'unu temizleme sorunları
regresyonlarla düzeltildi. Bu sonuçlar otomatik medya kurulumu veya fiziksel
cihaz kabulü yerine geçmez.

GitHub saklama politikası ve günlük görevin çalışma koşulları
[depolama temizliği belgesinde](github-storage-retention.md). Görevin çalışması için
Codex hostunun kullanılabilir olması gerekir; GitHub Actions cron işi değildir.
Container paketleri bu otomasyonun silme kapsamında değildir.

## Önceki geliştirme sırası (arşiv)

Bu tablonun sırası ve durumları yazıldığı tarihteki checkpoint'i anlatır.
Geçerli bağımlılıklar ve PR durumu için [güncel teslim sırasına](current-delivery-plan-2026-09-21.md)
ve [makinece doğrulanan kuyruğa](execution-queue.json) bakın.

Aşağıdaki mevcut işler korunur. Yeni G01–G11 grupları
[ayrıntılı plana](feature-expansion-plan-2026-09-05.md) göre bu işlerin arasına
yerleşir: S06/B1 ve S08/B3 temeli paralel; S07 otomatik medya bağlantıları ve
S09'un yazılım kurtarma bölümü erkenden tamamlanır. Yeni modüller yalnız kendi
bağımlılıklarını bekler. Son ortak tasarım, README ve fiziksel kabul tüm
seçili yazılım dilimlerinin ardından kalır.

Yarıda kalmaması için S06 kurulum koordinatörü ve B3 oturum/cache taşıması
[küçük teslimlere ayrıldı](remaining-core-integration-slices.md). Her dilimin
somut kabul koşulu vardır; yalnız model veya worker ilkeli eklemek uçtan uca
kurulum/yalıtımın tamamlandığı anlamına gelmez.

| Sıra | Paket / durum | Somut teslim ve bitti sayılma ölçütü |
| --- | --- | --- |
| 1 | **S05 — Hizmet yönetimi · kod ve uzak testler geçti** | Client admin ekranından bağlantı ekle/düzenle/unut/doğrula; şifreli Server kaydı, altı açık doğrulama durumu, yetki/oturum/çakışma testleri. Gerçek servis kabulü ayrı, servis kurulumu S06'da |
| 2 | **S06 — Eklenti sistemi · birleşik hazırlık uygulandı, kurulum eksik** | Altı bileşen için kalıcı hazırlık ve Client yönetimi; katalog/önizleme, kalıcı işler, Linux IPC ve açık politikayla Docker API/platform kontrolü mevcut. Birleşik kontrol ve daemon bağlamı da uygulandı. Sıradaki teslim: [sahiplikli imaj/dizin/ağ kaynakları](media-resource-preparation-plan-2026-09-05.md); ardından dar kurulum ve bootstrap |
| 3 | **S07 — CasaOS ve Music Assistant · sırada** | Tek Larenor Server kurulumu içinde medya ve Music Assistant; otomatik API anahtarı/adres/kütüphane eşleştirmesi, durum doğrulaması; Client'tan yalnız ayar yönetimi |
| 4 | **S08 — Merkezi entegrasyonlar · kimlik temeli eklendi** | Kalıcı Core/ev kimliği ve korumalı API hazır. Sırada Client cache sınırı, önce HA sonra medya/ağ adaptörleri, kaynak yetkileri, olay akışı ve widget sözleşmeleri; mevcut doğrudan yollar belgelenir |
| 5 | **Kalan ürün yetenekleri · sırada** | İleri kiosk ve kamera seçenekleri, Apple TV video, müzik sağlayıcıları ve HomePod kuyruk/grup/oynatma; yetenek matrisindeki desteklenmeyen durumları açık gösterme |
| 6 | **S09 — Ortak kurulum ve bütünlük · sırada** | Tek Larenor kurulumu ve dahili bileşenleri için kurulum/yedek/geri yükleme; özellikler arası akışlar, hata kurtarma, performans/güvenlik ve CI testleri |
| 7 | **G01–G11 — Seçilen 63 özellik · planlandı** | Güvenilir Core → kurtarma → tablet/bildirim → AI/otomasyon → eklentiler/çok ev → medya → aile → kamera → enerji → yeni cihazlar; bağımsız VNC/RDP/SSH dalı kendi ortak profil/güven kapıları hazır olunca paralel ilerler |
| 8 | **Son arayüz geçişi · işlevler tamamlanınca** | Apple tasarım ilkeleriyle ortak renk, tipografi, kart, gezinme, form ve diyalog sistemi; Dashboard, Media, Settings ve Server panelleri aynı düzende. Tek slogan korunacak |
| 9 | **Android tablet görsel kabul ve README · en son** | Huawei MatePad 11.5 S 2026 ve diğer tabletler, yatay/dikey yön, yeniden boyutlanan DeX penceresi, dokunma/klavye erişilebilirliği. Frontend bittikten sonra gerçek tablet görselleri; profesyonel README, ayrı Server/Client kurulumu, doğru GitHub konu etiketleri/açıklama ve insan/AI için açık belge gezinmesi. Telefon için ayrı tasarım hedefi yok |
| 10 | **Manuel kurulum ve fiziksel kabul · kullanıcıyla en son** | CasaOS/Proxmox kurulumu; sağlayıcı girişleri, gerçek HomePod/Chromecast/Apple TV, güç/kilit ekranı, güncelleme/geri yükleme senaryolarının cihazda doğrulanması |

Son tasarım aşamasında Flutter'a uygun Apple tasarım ve erişilebilirlik
becerileri uygulanacak; teknolojiye uymayan web becerileri uygulamaya zorlanmayacak.
README görselleri gerçek tablet düzenini temsil edecek; hazırlanmış taslaklar
çalışan uygulama ekranı gibi sunulmayacak.
Profesyonel README, keşfedilebilirlik ve gerçek kurulum yollarının son kontrolü
için [yayın hazırlık planı](readme-publication-plan.md) eklendi. GitHub açıklaması ve gerçek kapsamı anlatan 16 konu etiketi uygulandı; yıldız veya AI görünürlüğü artışı garanti edilmeyecek.

## Manuel kurulum ve fiziksel kabul

- CasaOS Docker veya Proxmox Linux VM kurulumu **en sonda kullanıcıyla manuel**
  yapılacak. Güncel geliştirme ev sunucusuna kurulmuş değildir.
- Spotify, Apple Music ve YouTube Music yetkilendirmesi; Music Assistant,
  HomePod, Chromecast ve Apple TV üzerinde gerçek arama/kuyruk/oynatma kabulü.
- Huawei MatePad 11.5 S 2026 ve diğer tabletler; Samsung DeX, dokunmatik monitör,
  ekran kapalı ses, kilit ekranı ve OEM güç davranışları.
- Sağlık sağlayıcısı/cihaz izinleri, yönetilen kiosk için fiziksel cihaz kabulü.
- Netelsan Algan 7'nin tam donanım revizyonu ve elektronik köprü; gerçek zil,
  kamera ve kapı davranışı. Yazılım temeli fiziksel bağlantı tamamlandı demek değildir.
- Gerçek Server üzerinden aynı imzalı Client yükseltmesi ve yeniden kurulumdan
  sonra hesap/kasa geri yükleme kabulü.

Üretim Home Assistant üzerindeki kontroller salt okunur kalır. Native iOS
platform dosyaları kaldırılmıştır; Client Android tablet ve DeX ürünüdür.

## Önceki test kanıtı

| Çalıştırma | Sonuç | Sınır |
| --- | --- | --- |
| Tam Server API/depolama/sürüm/iş paketi | **1.515 geçti; 1 Linux testi Mac’te atlandı** | Gerçek Java/apksig dahil bütün `server/tests`; sentetik servisler ve yerel IPC, canlı ev sunucusu değil |
| Tam Flutter paketi | **2.625 geçti** | Birleşik medya hazırlığı, bağlam ve sayfalama, hesap/yaşam döngüsü ve ortak JSON sözleşmeleri dahil unit/widget kapsamı |
| Bütün Python araç/politika testleri | **178 geçti** | Yeni container medya yolculuğu dahil; gerçek imaj çalışması GitHub CI'da ayrıca doğrulanır |
| Birleşik medya kontrol işleri | **116 odaklı test**, **%99 satır/dal** | Model/API/şema %100; gerçek HTTP→Unix→restart ortak JSON, şifreli sonuç, idempotence, iptal ve yetki yarışları |
| Client birleşik kontrol | **160 ilgili test**, **%93,8 satır** | Yeni alan 680/725 satır; aynı Server JSON örneği, beklenen Core/ev sınırı, EN/TR ve büyük yazı |
| Daemon bağlamı | **179 geçti; 1 Linux testi Mac’te atlandı**, **%94 satır/dal** | Socket pidfd, thread/proc/root/mount kimlikleri; gerçek ev Docker'ı kullanılmadı |
| Host/IPC son bağımsız inceleme | **120 geçti**, **%95 satır/dal** | Host %98, IPC %91; ortak bütçe, path değişimi, tek süre sınırı, bozuk nested sonucun reddi |
| Birleşik medya planner'ı | **83 geçti**, **%97 birleşik kapsam** | Altı bileşen, güvenli katalog, değişmez hash/kimlikler; host I/O veya kurulum yok |
| Medya API/depolama/ortak sözleşme | **75 geçti**, **%92 birleşik kapsam** | Şema/API/model %100; şifreleme/AAD, paralel tekrar/iptal, restart, katalog/yetki ve 8/256 sınırları |
| Client medya hazırlığı | **52 geçti**, 18 widget; **%95,3 satır** | İlgili katalog/iş/bağlamlarla birlikte 237 test; farklı Core, 256 kayıt erişimi, belirsiz POST, 2× yazı ve erişilebilir alanlar |
| Container medya smoke protokolü | **29 ilgili test**, helper **%100 kapsam** | `19b14aa` CI'ında gerçek amd64/arm64 imajlarında oluştur/restart/iptal geçti; medya servisleri kurulmadı |
| Emülatör hazırlığı | **21 araç regresyonu geçti** | Sınırlı tekrar, QEMU kanıtı, kesin ayar değeri ve hata halinde derleme başlamaması; `19b14aa` gerçek E2E önkoşulu ilk denemede geçti |
| Client gereksinim işleri | **53 geçti**, 19 widget; **%94,8 satır** | Tam Flutter toplamının içindeki odaklı kapsam; fiziksel tablet kabulü değil |
| Docker ve politika bütünleştirmesi | **236 geçti**, üç modülde **%99 birleşik satır/dal** | Docker probe %96; host/runtime %100. Sonradan eklenen dördüncü yavaş-daemon journey de geçti; fiziksel daemon kabulü değil |
| Kalıcı Core/ev kimliği ve ortak sözleşme | **59 Server / 63 Client testi geçti** | Yeni Server modülü ve Client model/metot %100 kapsam; çoklu ev ve Client oturum/cache henüz yok |
| Dahili işçi CLI | **47 geçti**, **%100 kapsam** | Politika/izin, statik hata ve durdurma testleri; gerçek kurulum yok |
| İşçi IPC bağımsız incelemesi | **83 testlik ilgili koşum**; 201/216 statement, 59/68 dal | 16 temel IPC testi ve başlatma hataları dahil; kapsamdaki diğer dosyalarla toplanmaz |
| Kalıcı iş bağımsız incelemesi | **55 geçti**, **%89 birleşik kapsam** | Yetki, kalıcılık, iptal, idempotence, bozulma ve restart; Server toplamının içindedir |
| Önceki yerel Android native koşumu | **98 geçti**, 18 test paketi | Güncel S06 için yeni fiziksel kurulum/oynatma kanıtı değildir |
| Uzak API 35 x86_64 E2E (`62b2054`) | **4 uygulama + 4 platform senaryosu geçti** | Gerçek emülatör 36.1.9.0; 42/42 işaret ve yaklaşık 8:39 script süresi. Fiziksel tablet kabulü değil |

Test dosyaları, kapsam ve açıklar [test matrisinde](testing-matrix-2026-09-05.md).
Test adetleri farklı zaman ve kapsamları temsil eder; toplanarak başarı oranı
üretilmez. CI kanıtı yukarıda adı verilen commit içindir; yalnız belge değişiklikleri uygulama veya workflow kodunu değiştirmez.

## Güncelleme kaydı

- **27 Eylül — F11 uygulandı, F12 başladı:** Paketli mini eklenti yalnız mevcut
  Core/ev kapsamındaki `home.resource_count.read` yeteneğini çalıştırıyor. Ağ,
  host dosyaları, anahtarlar, host yönetimi, keyfi kod ve evler arası erişim
  kapalı; CPU/bellek/çıktı bütçeleri, HMAC doğrulamalı sınırlı journal ve
  durdurma sonrası yürütme reddi görünür Client akışına bağlandı (`7af0d3e4`,
  `2e10d86d`). F11 son test/inceleme/exact-head CI tablosuna taşındı; F12
  yetkili MCP kapısı aktif geliştirmeye alındı. Kabul sayaçları kanıtlar gelene
  kadar **37/125** ve **3/63** olarak korunuyor.

- **27 Eylül — F01 uygulandı, F11 başladı:** Sürümlü izinli eylem kataloğu yalnız
  tam ifadeleri şema doğrulamalı otomasyon taslağına çeviriyor; hedef, adımlar,
  yan etkiler ve süre görünür. Ham döküm saklanmıyor, prompt enjeksiyonu
  reddediliyor ve açık onay atomik biçimde yalnız etkisiz kural kaydı
  oluşturuyor; cihaz komut yolu kapalı (`2d57cf02`, `aab8009d`). F01 son
  test/inceleme/exact-head CI tablosuna taşındı; bağımlılıkları hazır F11
  sınırlı mini eklenti çalışma alanı aktif geliştirmeye alındı. Kabul sayaçları
  kanıtlar gelene kadar **37/125** ve **3/63** olarak korunuyor.

- **27 Eylül — F03 uygulandı, F01 başladı:** F02 deneme haftasının sürümlü
  tarihsel olayları önerilen kural sürümüyle deterministik yeniden oynatılıyor;
  eski/yeni karar farkı ve girdi parmak izi gösteriliyor. Eksik geçmiş
  `unknown`; adaptör ve canlı kuyruk yazmaları sabit sıfır (`a8f8c662`). F03
  son test/inceleme/exact-head CI tablosuna taşındı ve bağımlılıkları açılan
  F01 şema doğrulamalı otomasyon taslağı aktif geliştirmeye alındı. Kabul
  sayaçları **37/125** ve **3/63** olarak korunuyor.

- **27 Eylül — F02 uygulandı, F03 başladı:** IANA saat diliminde yedi yerel
  takvim günü, DST UTC süre/fold görünürlüğü, gerçek ve sentetik olaylar,
  öncelik/zaman penceresine göre tetiklenen-bastırılan kararlar ve her katmanda
  sabit sıfır adaptör yazması Core ile Client akışına bağlandı (`5be635bf`,
  `50f349cc`). F02 son test/inceleme/exact-head CI tablosuna taşındı; açılan
  F03 geçmiş tekrar sınaması aktif geliştirmeye alındı. Kabul sayaçları bu
  kanıtlar gelene kadar **37/125** ve **3/63** olarak korunuyor.

- **27 Eylül — F07 uygulandı:** Hesap/ev yalıtımlı alışkanlık gözlemleri,
  sınırlı zaman serisi, tazelik ve asgari örnek/zaman aralığı kapıları, robust
  MAD tabanı, açık `unknown` sonucu, model sürümü ve normal/yanlış alarm geri
  bildirimi Core ile görünür Client ekranına bağlandı (`c59e96cf`, `c491b748`).
  F07 aktif geliştirme tablosundan çıkarılıp son test/inceleme/exact-head CI
  tablosuna taşındı. Kabul sayaçları bu kanıtlar gelene kadar bilinçli olarak
  **37/125** ve **3/63** kaldı.

- **27 Eylül — tek dal geliştirme:** K13 yönetilen profil dağıtımı, F04 kural
  hakemi, F09 süreli AI hafızası ve F10 kanıta dayalı teşhis Core ve görünür
  Client akışlarıyla uygulandı. Her dilim
  `codex/project-completion-100` dalına ayrı commit olarak gönderildi. Bu dört
  iş artık aktif geliştirme tablosunda değildir; özellik testleri, bağımsız
  inceleme ve exact-head CI son toplu doğrulama aşamasına bırakıldığı için
  `implemented` durumunda, “Tamamlanan ve test/CI bekleyen işler” tablosundadır.
  Kanıtla kabul sayaçları bilinçli olarak **37/125** ve **3/63** kaldı; gerçek
  DPC/OEM cihaz kabulü ayrıca `MANUAL.KIOSK` kapısında açıktır.

- **19:42:** Kullanıcının sürekli devam talimatıyla kalan adımların kalıcı
  yürütme kuyruğu hazırlanıyor; mevcut takip 15 dakikalık geliştirme devamına
  genişletildi, günlük debug APK temizliği aynı sınırlarla korundu.
  S06.3a saf kaynak sözleşmesi `8ab8006` RED → `0de91a2` GREEN: 67 yeni,
  katalog/stack ile 249 test geçti. Kaynak journal'ı ve imaj akışı paralel;
  kurulum yetkisi açılmadı, fiziksel ev işlemi yapılmadı.

- **19:22:** S06 dilim 2 tamamlandı, koordinatör **2/6**. `62b2054` bütün
  CI ve imzalı APK 86 teslimi geçti; APK yerelde ayrıca doğrulandı.
  1.516 Linux Server, 2.625 Flutter, 98 JVM/Robolectric, 8 E2E, 178 araç testi;
  iki mimarili imaj ve anonim index doğrulaması başarılı. `072aa8a` son tam
  regresyonunda bulunan üç eski test taklidi `62b2054` ile güncellendi;
  eski koşular concurrency ile iptal edildi. Sonraki kaynak hazırlığı altı
  adıma ayrıldı; yeni özellik kabulü hâlâ 0/63, gerçek ev kurulumu yok.

- **18:24:** `19b14aa` Güvenlik, Server ve Android CI'ı imzalı APK 84 teslimi
  dahil başarılı. 1.273 Server, 2.572 Flutter ve yerelde 176 araç testi;
  gerçek emülatörde 4 native + 4 uygulama senaryosu, 42 aşama işareti geçti.
  İki mimarili medya restart/iptal imajı yayımlandı, anonim manifest doğrulandı.
  Dilim 2 için daemon bağlamı, ortak süre sınırı, değişen yol, toplam dosya
  sistemi bütçesi ve ağ bilinmezliği beş somut kabul senaryosuna ayrıldı.
  Uzak erişim F61–F63 planlandı; protokol motorları henüz uygulanmadı.
- **18:00:** `ce1ce38` Server/Güvenlik ve gerçek iki mimarili medya restart
  akışı geçti; anonim imaj manifesti doğrulandı. Android analiz ve debug/native
  başarılı; E2E hazırlıkta durdu, imzalı APK üretilmedi. Ayarı doğrulamayı
  gevşetmeden 21 regresyonlu, süre/çıktı sınırları olan hazırlık düzeltmesi
  eklendi; bütün araç paketi 176 testle geçti. Uzak erişimde kişisel bağlantının
  Core gerektirmediği ve açık
  oturumların çıkış/hesap/ekran değişimindeki kapanış politikası netleştirildi.
- **17:40:** S06 ilk dilimi 2.572 Flutter, 1.273 Server ve 169 araç testiyle
  yerelde doğrulandı. Bağımsız incelemenin boş/bozuk şema, farklı Core
  tarihçesi, eski kayıt erişimi ve son erişilebilirlik/sınır bulguları düzeltildi.
  Gerçek iki mimarili imaj smoke'una hazırlık → restart → aynı kayıt → iptal
  eklendi. VNC/RDP/SSH F61–F63 olarak onaylı plana eklendi; toplam 63,
  yeni kabul 0/63. Protokoller Client'ta, ortak profil/kasa isteğe bağlı Core'da.

- **17:27:** `21bbf58` üç CI kapısından geçti; imzalı APK-82 teslim edildi.
  S06 dilim 1 için altı bileşenli plan, şifreli hazırlık, HTTP/Client sözleşmesi
  ve yönetici ekranı uygulandı. Jellyfin ortak kütüphanesindeki salt okunur
  amaç uyuşmazlığı düzeltildi. Bağımsız inceleme ve yeni tam testler sürüyor;
  kurulum/otomatik eşleştirme ve B3 oturum/cache sınırları açık kalıyor.

- **16:57:** `e73533e` Android/Güvenlik/Server CI tamamen başarılı;
  `app-signed-release-apk-81` imzası doğrulanarak teslim edildi. Gerçek ev
  Server'ına yayın yapılandırılmadığından atlandı. Son ortak sözleşme dilimi
  1.103 Server, 2.520 Flutter, 159 araç testi, analiz/format/sır taraması
  kanıtlarıyla yeni push için hazır; önceki koşum onun CI'ı yerine sayılmaz.

- **16:50:** `e73533e` uzak Android E2E **8/8 geçti**. Emülatör pininin
  gerçekten yüklendiği ve bütün uygulama aşamalarının tamamlandığı doğrulandı;
  timeout/assertion sınırları gevşetilmedi. İmzalı APK işi sürüyor.

- **16:44:** `e73533e` Server/Güvenlik CI başarılı; iki mimaride kimlik restart
  kontrolü geçti, Android sürüyor. Ortak 27 JSON örneği Server ve Client'a
  bağlandı; bool/float şema kabulü düzeltildi. Tam Server 1.103 test geçti;
  Client 63 ilgili test ve tam 2.520 Flutter testi geçti; analiz temiz.
  [Sonraki küçük teslimler](remaining-core-integration-slices.md)
  açıklandı; cache izolasyonu ve otomatik medya kurulumu hâlâ açık.

- **16:32:** Kesilen işlerden S06 Docker kontrolü ve B3 kalıcı Core/ev kimliği
  tamamlandı; tam 1.075 Server, 2.479 Flutter ve 159 araç testi geçti.
  `5deb1e6` Server/Güvenlik CI başarılı; Android native 4/4 sonrası emülatör
  kaybı nedeniyle E2E başarısız. Yeni pin ve aşama tanılaması hazır; yeni
  commit'in CI sonucu bekleniyor. [Docker kanıtı](docker-preflight-implementation-2026-09-05.md)
  ve [kimlik kanıtı](core-context-implementation-2026-09-05.md) eklendi.

- **15:55:** Kullanıcı 60/60 yeni özelliği seçti. Seçim JSON'a kaydedildi;
  her özellik 10 teslim grubunda tekil ID, bağımlılık ve kabul ölçütüyle
  mevcut kuyruğa bağlandı. Eski yaklaşık %65 yalnız önceki kapsam olarak
  ayrıldı; yeni kabul 0/60, genişletilmiş toplam henüz hesaplanmadı.
  Tam Flutter analizi de temiz sonuçlandı. Yeni kurulum veya cihaz işlemi yok.

- **15:40:** S06 kalıcı salt okunur gereksinim işleri, Linux IPC ve Client
  geçmiş/iptal/istek kurtarma akışı `5c6b83b` üzerinde yerelde doğrulandı:
  2.477 Flutter, 921 Server ve 157 araç testi. Henüz gönderilmedi; yeni CI ve
  tam analiz sonucu bekleniyor. `09729be` güvenlik ve iki mimarili Server yayını
  başarılı; Android E2E Quickstep ANR/odak hatası açık. Yaklaşık %65 tahmini
  korundu; yeni 60 fikir seçim bekliyor ve kapsama eklenmedi.

- **14:14:** Katalog/önizleme dahil **653 Server testi** geçti; işçi testleri
  bu koşuma henüz dahil değil. Ortak Python/Dart katalog-plan sözleşmesi için
  ayrıca bir API testi geçti. Wheel içindeki paketlenmiş katalog bağımsız
  açılarak doğrulandı. Android E2E odak/grafik düzeltmesi `8346c01` ile gönderildi;
  yeni CI sürüyor. Birleşik medya kurulum otomasyonu sıradaki ana iştir.

- **14:11:** Kullanıcının yeni kararı işlendi: Music Assistant ve tüm medya
  bileşenleri tek Larenor Server kurulumu içinde, API bağlantıları otomatik;
  Client'ta yalnız ayar yönetimi. Eski MA-only kurulum belgesi geçiş referansı
  olarak işaretlendi. Katalog ekranı dahili bileşen gereksinimleri ekranına
  uyarlandı; kurulum ve bağlantı otomasyonu henüz tamamlandı sayılmıyor.

- **14:01:** S05 `88c26fc` ile yayımlandı. Güvenlik ve iki mimarili Server CI
  başarılı; Android CI sürüyor. GitHub About açıklaması ve 16 konu etiketi
  uygulandı ve geri okunarak doğrulandı. S06 katalog/önizleme/işçi geliştirmesi
  sürüyor. Genel kapsam tahmini **%65** olarak korundu; henüz bitmemiş S06 veya
  fiziksel kabul tamamlanmış sayılmadı. Final README ve görseller frontend sonrası.

- **13:49:** S05 tamamlanmış kod dilimi: 17 servis türü, Client admin akışı,
  türüne uygun kimlik bilgisi alanları ve ortak JSON sözleşmesi. Son 2.333 Flutter,
  529 Server, 114 araç testi geçti; analiz ve 747 Dart dosyasının biçimi temiz.
  CI için yeniden başlatma portu ve emülatör kaynak/tanı düzeltmeleri hazır.
  Son sır taraması ve GitHub gönderimi yapılıyor; S06 katalog çalışması ayrı sürüyor.
- **13:39:** Tam 2.327 Flutter testi, 106 araç testi ve analiz geçti. Ortak JSON
  sözleşmesi hem FastAPI hem Dart Client tarafından doğrulandı. Kaynak üretimi
  ve imaj dosya izni düzeltmeleri `773a02e` ile gönderildi. Server gerçek imza
  testini geçti; yeniden başlatma testinin port varsayımı düzeltiliyor. Yeni
  görseller frontend sonrasına bırakıldı; README/etiket/kurulum yayın planı eklendi.
- **13:16:** Yaklaşık %65 ilerleme çubuğu ve dokuz açık teslim adımı eklendi.
  Server'a taşınan hesap/kasa/yayın ile hâlâ Client'ta çalışan entegrasyonlar
  ayrıldı. Music Assistant'ın henüz yönetilen servis olmadığı ve HomePod fiziksel
  kabulünün beklediği açıklandı. Son tasarım ve README için tablet/DeX önceliği
  kaydedildi. S05 CRUD 63 test geçti; son Server CI başlatma hatası inceleniyor.
- **12:47:** `473132e` GitHub'a gönderildi ve uzak dosya doğrulandı. Güvenlik
  CI başarılı; Android ve Server imajı işleri çalışıyor. Yerel takip dosyası bu
  sonucu yansıtır; devam eden yayın kontrollerini geçersiz kılmamak için yalnız
  durum kaydıyla yeni bir `main` commit'i oluşturulmadı.
- **12:45:** Artifact kotası CI düzeltmesi eklendi; dört yeni tarama hata
  yayılım testiyle araç paketi 97/97 geçti. Yayın paketi yerelde doğrulandı;
  GitHub CI ve gerçek Server imajı sonucu ayrı bekleniyor.
- **12:38:** Tam 2.297 Flutter ve 98 native test geçti; analiz temiz. Kullanıcının
  ilerleme sorusu için genel kapsam tahmini %60–65 olarak eklendi. CI rapor
  yükleme sorunu çözülmeden bulut CI başarılı olarak işaretlenmiyor.
- **12:33:** Güncelleme uyarısı, altı ekran önizlemesi ve Docker/CI kodu tamamlandı.
  93 Python araç testi ve tüm workflow'larda actionlint geçti. Birleşik son
  testler ve bağımsız kod incelemesi sürüyor; gerçek imaj doğrulaması bekliyor.
- **12:27:** Tek takip dosyası oluşturuldu; güncelleme uyarısı, Server imajı,
  ekran önizlemeleri ve son bütünleştirme aktif işlere alındı. Yerel çalışma ile
  yayımlanmış commit ve fiziksel kabul ayrıldı.

### 30 Eylül F45 kaynak metadata ve yeniden izin kabulü

Yerel kaynak ayarları Frigate erişimi olmadan okunur; kayıtlı kaynak çevrimdışıyken de exact revision ile devre dışı bırakılır. Yeni veya yeniden verilmiş izin öncesi ayrı authenticated discovery kamera/oda yetkisini ve ses sınıflarını doğrular. Yetki ya da provider drift eski history için unavailable + boş sonuç üretir. 12 Server, 15 Flutter ve gerçek Client→normal Core→TCP kabulü geçti; analyze temiz. Sayaçlar 37/126 ve 3/63 olarak korunur; geniş kabul/CI ve fiziksel ses kapısı açık.

### 30 Eylül F50 gerçek Client ve kayıp yanıt uzlaştırması

Client→normal Core→authenticated HA TCP/WebSocket yolu kaynak keşfi, entity binding, gerçek gözlem, explicit confirm ve readback ile doğrulandı. İlk başarılı Core yanıtı düşürüldüğünde Client aynı preview/token ile kayıtlı sonucu alır; HA bir kez değiştirilir. Pending failed confirm varken refresh yeni intent açamaz; preview süresi geçse de aynı attempted intent uzlaştırılabilir. 17 Server, 28 Flutter ve 1 gerçek TCP kabulü geçti; analyze temiz. 37/126 ve 3/63 sayaçları korunur; geniş kabul/CI açık.

### 30 Eylül F56 tuş düzenleyici ve gerçek IR öğrenme isteği

19 mantıksal tuş admin ekranından CAS ile eklenir/değiştirilir/kaldırılır. Gerçek HA Broadlink destek biti doğrulanmadan öğrenme gönderilmez; öğrenme girişimi önce kaynak revizyonunu artırıp eski previewları iptal eder. HA public API öğrenilmiş kodu veya fiziksel IR teslimini doğrulamadığından makbuz uncertain kalır. 18 Server, 19 Flutter ve gerçek Client→normal Core→authenticated HA TCP/WS send+learn kapısı geçti; analyze temiz. [Kanıt ve sınırlar](testing/f56-broadlink-command-editor-2026-09-30.md). Sayaçlar 37/126 ve 3/63; geniş exact HEAD CI ve fiziksel IR kabulü açık.

### 30 Eylül F42 gerçek mahremiyet dönüşümü ve paylaşım

Normal Core, yetkili gerçek Frigate klibini sabit full-frame blur ile işler. FFmpeg/ffprobe için bounded admission, boyut/süre/frame limiti, çıktı metadata temizliği ve authority drift sırasında process group iptali uygulanır. Client gerçek recipient/policy/consent seçimi, preview, şifreli süreli paylaşım, download ve revoke yolunu kullanır. 18 Server, 4 Flutter ve gerçek Client→normal Core→TCP Frigate→FFmpeg kapısı geçti; analyze temiz. [Kanıt ve sınırlar](testing/f42-private-event-sharing-production-2026-09-30.md). 37/126 ve 3/63 korunur; geniş exact HEAD CI ve fiziksel mahremiyet kapısı açık.

### 30 Eylül F57 gerçek mqtt_room ve çevrimdışı rıza iptali

Normal Core enabled mqtt_room registry ve gerçek HA state/distance kontratıyla oda eşlemesi yapar. Aynı transaction içinde şifreli kaynak ve reducer kaydedilir; callback hatası ikisini de geri alır. Offline exact-CAS rıza iptali evidence/previews/receipts temizler; inactive kaynak provider I/O yapmaz. Inline admin kurulum, yeniden canlı discovery ve explicit rıza yolu vardır. 19 Server, 18 Flutter ve analyze geçti. [Kanıt ve sınırlar](testing/f57-home-assistant-mqtt-room-runtime-2026-09-30.md). Gerçek Client TCP ve geniş exact HEAD CI açık; sayaçlar 37/126 ve 3/63.

F57 gerçek Client ek kapısı: üretim Flutter account APIları → normal Uvicorn Core → authenticated HA TCP/WS, 1 geçti. Candidate→present için iki güncel gözlem, HA offline olduktan sonra zero-I/O exact-CAS revoke ve stale revision reddi doğrulandı. Geniş exact HEAD CI ve fiziksel BLE kabulü açık.
