# FINAL.FUNCTION — görünür alt işler, 3 Ekim 2026

Kuyruk JSON'u durumların tek kaynağıdır; EXECUTION_QUEUE.md aynı kaynaktan
üretilir. Özel hazırlık veya yerel derleme kabul edilmiş özellik sayılmaz.

| Alt iş | Şu anki durum | Kanıt / sıradaki somut kapı |
| --- | --- | --- |
| F60 RI5 launch/resume ve strict paket kimliği | Exact847 terminal hata; sıralı handoff yerelde geçti | Run37134249192 xi2ChildExit; key observer reap sonrası pointer observer düzeltmesi82test+Ruff. Kısa exact5a715 probe37135929910 keyListener aşamasında başarısız; xmodmap dependency/tanı düzeltmesi83test geçti. Exact15ba probe37136733239 geçti: gerçek overlap xi2ChildExit, ordered handoff klavye/pointer/button etkisi geçti. Strict Android37136853828 instrumentation öncesi owned host process API readiness çıkışıyla başarısız; bounded startup tanısı hazırlanıyor |
| F62 mikrofon4 ve SAF grant5 | Commit edildi, pushlandı | 06ef24fae / 0cb84d079 yerel native/Flutter/AndroidTest kanıtları; gerçek dosya aktarımı veya Gateway kabulü değildir |
| F62 audio/mic effect-control | Okuyucu düzeltmesi yerelde doğrulandı; hosted etkiler açık | Tek bounded read absent/unavailable ayrımını korur; exact consume başarılı olmadan faz ilerlemez. Root 73 runner +11 workflow =84 geçti, Ruff temiz. f201 host hatası ve gerçek ses/mikrofon kabulü açık |
| F62 SAF mirror ve kalıcı aktarım günlüğü | Cold recovery özel kaynakta tamamlandı; bağımsız inceleniyor | Production coordinator encrypted exact grant ve persisted izinle salt okunur readback recovery yapar; followup2 23test geçti fakat çapraz inceleme iki P1 buldu: native drain kapanışı ve cold COMPLETE→prepare cleanup borcu. Followup3 27test geçti; inceleme gerçek bridge.dispose drain bypass, UI block, timeout executor leak ve same-process COMPLETE cleanup yarışı buldu. Followup4 onarımı aktif; root bileşim/hosted etkiler açık |
| F62 gerçek dosya kanalı kotası | Özel kaynak dondu; actual Android derlemesine alındı | Mac effect/ASAN/UBSAN/TSAN kapıları 4/4; proc-FD inode pin, 32 dosya/256 MiB/1 GiB, read/browse/mutation guard. Linux proc ve Android kanal etkisi açık |
| F62 native v5 yaşam döngüsü | Özel birleşik actual derleme ve odaklı kapılar geçti | Root177native/0skip (118RDP+59Moonlight), AndroidTest compile315; actual iki AAR source/API/ELF/receipt/verify-install. Root portable22/27subtest. Product Gateway/files false; gerçek kanal etkisi açık |
| F62 Flutter schema6 ve Core profili | Yerel bileşim geçti; durable candidate intent incelemede | Root145Flutter/analyze, Core25, admission13native+23tablet; followup4 durable retirement index21vault+24tablet/analyze ve bağımsız inceleme geçti; root admission korundu, özel bileşime alındı. Android keystore/live Gateway kanıtı açık |
| F62 RD Gateway | Gerçek owned fixture ve Android senaryosu hazırlanıyor | Gerçek RDPDR ToRemote/FromRemote hedefi düzeltildi;42 portable test geçti. Root fixture45test+Ruff/actionlint ve actual Android senaryo derlemesi278task/15contract geçti. Exact15ba Linux probe37136737506 unsafeArchive build hatasında tamamlandı; gerçek arşiv top-level directory dar düzeltmesi root30test+15subtest/Ruff geçti; değişmiş exact950eda Linux37137081865 Gateway/auth build geçti, FreeRDP build ve read-only Go module cleanup başarısız. Root yeni closed configure/compile tanısı+owned cleanup 37test/8subtest+14selftest/Ruff/actionlint geçti; değişmiş kaynak koşusu sırada. authenticated Gateway→target ve Android SAF upload/save/readback kabulü açık |
| F62 aktarım durumunun kullanıcıya iletilmesi | Özel kaynak düzeltmesi geçti; kabul açık | Son asynchronous drain sonucu ekrana yansımıyordu. EN/TR4RED→4GREEN; full panel/controller/schema6 75test geçti, 5-item analyze temiz. Sealed açık kaydetmeyi açar; unknown açmaz; otomatik SAF save yok |
| FINAL.FUNCTION teslimi | Açık | Tüm yazılım maddeleri tam kabul ve bağımlılık kanıtlarıyla onaylanacak; final dal HEAD required CI yeşil olacak; sonra main merge ve ancestry/içerik doğrulaması |
| FINAL.UI başlangıcı | Bekliyor | Yukarıdaki kabul ve merge doğrulanmadan başlamaz. Güncel main'den ayrı tek dal kullanılacak |

Üç ajan yalnız bu final içinde bağımsız açık kapılarda çalışıyor: exact-owner SAF kurtarma; durable parola temizliği ve gerçek Android kabul senaryosu; gerçek Linux Gateway/RDPDR fixture. Root Gateway erişim kapısı, entegrasyon, kuyruk ve Git’i yönetiyor. İkinci final çalışılmıyor.

F60 yeni terminal hata nedeniyle yeniden aktif; F62 de aktif. **69 iş / 58
seçili özellik CI bekliyor**. Kabul **35/127 (%27,6)** ve **3/63 (%4,8)**
değişmedi. [Yeni exact hata kanıtları](native-strict-7950-f201-failure-2026-10-03.md).
[Gerçek Linux observer probe](f60-owned-input-probe-2026-10-03.md) ve
[F62 bounded reader düzeltmesi](f62-effect-control-read-2026-10-03.md) kabul yerine sayılmaz.

Eski CI hataları korunuyor; aynı kaynak körlemesine rerun edilmiyor. Fiziksel
cihaz/gerçek ev servisi/hesap kapıları MANUAL kayıtlarında açık kalır. Probe,
controller testi veya private port, özellik kabulünün yerine geçmez.
