# FINAL.FUNCTION — görünür alt işler, 3 Ekim 2026

Kuyruk JSON'u durumların tek kaynağıdır; EXECUTION_QUEUE.md aynı kaynaktan
üretilir. Özel hazırlık veya yerel derleme kabul edilmiş özellik sayılmaz.

| Alt iş | Şu anki durum | Kanıt / sıradaki somut kapı |
| --- | --- | --- |
| F60 RI5 launch/resume ve strict yayın | Tam strict koşu başarısız; dar fixture onarımı | Exact7e552/37140213824 original1/1/0/0 ownedInputEffects; ilk frame/PCM/listener geçti. Relative axis/iki hareket/host deadline kaynak kusurları düzeltiliyor; actual input/iki yaşam/kapanış açık |
| F04 aynı cihaz dispatch | Yeniden çalışılıyor | Independent P1: superseded ownership provider çağrısına ulaşabilir; serialized admission/send ve concurrency/expiry/cancel kapısı açık |
| F19 çoklu Core | Yeniden çalışılıyor | Independent P1: rejection/restore collision/data-search-cache ve named required CI açık; eski successful dual-authority kanıtı korunur |
| F62 mikrofon4 ve SAF grant5 | Commit edildi, pushlandı | 06ef24fae / 0cb84d079 yerel native/Flutter/AndroidTest kanıtları; gerçek dosya aktarımı veya Gateway kabulü değildir |
| F62 audio/mic effect-control | Okuyucu düzeltmesi yerelde doğrulandı; hosted etkiler açık | Tek bounded read absent/unavailable ayrımını korur; exact consume başarılı olmadan faz ilerlemez. Root 73 runner +11 workflow =84 geçti, Ruff temiz. f201 host hatası ve gerçek ses/mikrofon kabulü açık |
| F62 SAF mirror ve kalıcı aktarım günlüğü | Cold recovery özel kaynakta tamamlandı; bağımsız inceleniyor | Production coordinator encrypted exact grant ve persisted izinle salt okunur readback recovery yapar; followup2 23test geçti fakat çapraz inceleme iki P1 buldu: native drain kapanışı ve cold COMPLETE→prepare cleanup borcu. Followup3 27test geçti; inceleme gerçek bridge.dispose drain bypass, UI block, timeout executor leak ve same-process COMPLETE cleanup yarışı buldu. Followup4 dört production drain/cleanup hatasını kapattı. Yeni UNKNOWN persistence-failure→late completion duplicate callback açığı için followup5 dar onarımı doğrulanıyor; root bileşim/hosted etkiler açık |
| F62 gerçek dosya kanalı kotası | Özel kaynak dondu; actual Android derlemesine alındı | Mac effect/ASAN/UBSAN/TSAN kapıları 4/4; proc-FD inode pin, 32 dosya/256 MiB/1 GiB, read/browse/mutation guard. Linux proc ve Android kanal etkisi açık |
| F62 native v5 yaşam döngüsü | Özel birleşik actual derleme ve odaklı kapılar geçti | Root177native/0skip (118RDP+59Moonlight), AndroidTest compile315; actual iki AAR source/API/ELF/receipt/verify-install. Root portable22/27subtest. Product Gateway/files false; gerçek kanal etkisi açık |
| F62 Flutter schema6 ve Core profili | Yerel bileşim geçti; durable candidate intent incelemede | Root145Flutter/analyze, Core25, admission13native+23tablet; followup4 durable retirement index21vault+24tablet/analyze ve bağımsız inceleme geçti; root admission korundu, özel bileşime alındı. Android keystore/live Gateway kanıtı açık |
| F62 RD Gateway | Linux build linker aşamasında başarısız; target/symbol tanısı açık | Exact7e6d/37141178524 compile/linkerError/linkUndefined exit1; closed699B source pins doğrulandı. Private200JVM/313task compile gerçek Gateway/SAF etkisi değildir; DIRECT/PUBLIC/audio/mic/final CI açık |
| F62 aktarım durumunun kullanıcıya iletilmesi | Özel kaynak düzeltmesi geçti; kabul açık | Son asynchronous drain sonucu ekrana yansımıyordu. EN/TR4RED→4GREEN; full panel/controller/schema6 75test geçti, 5-item analyze temiz. Sealed açık kaydetmeyi açar; unknown açmaz; otomatik SAF save yok |
| FINAL.FUNCTION teslimi | Açık | Tüm yazılım maddeleri ve bağımlılıkları tam kabul edilecek; final dal exact HEAD required CI yeşil olacak; sonra main merge ve ancestry/içerik doğrulaması yapılacak |
| FINAL.UI başlangıcı | Bekliyor | Yukarıdaki kabul ve merge doğrulanmadan başlamaz. Güncel main'den ayrı tek dal kullanılacak |

Çalışma yalnız bu final içindeki F04/F19/F60/F62 açık kapılarıyla sınırlıdır. Özel hazırlıklar, yerel derlemeler ve çalışan koşular kabul veya merge sayılmaz. Root kuyruk, Git ve exact hosted kabulü yönetiyor; ikinci final çalışılmıyor.

F04/F19 independent P1 ve F60/F62 terminal hataları nedeniyle yeniden aktif. **67 iş / 56
seçili özellik CI bekliyor**. Kabul **35/127 (%27,6)** ve **3/63 (%4,8)**
değişmedi. [Yeni exact hata kanıtları](native-strict-7950-f201-failure-2026-10-03.md).
[Gerçek Linux observer probe](f60-owned-input-probe-2026-10-03.md) ve
[F62 bounded reader düzeltmesi](f62-effect-control-read-2026-10-03.md) kabul yerine sayılmaz.

Eski CI hataları korunuyor; aynı kaynak körlemesine rerun edilmiyor. Fiziksel
cihaz/gerçek ev servisi/hesap kapıları MANUAL kayıtlarında açık kalır. Probe,
controller testi veya private port, özellik kabulünün yerine geçmez.
