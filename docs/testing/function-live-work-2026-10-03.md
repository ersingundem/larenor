# FINAL.FUNCTION — görünür alt işler, 3 Ekim 2026

Kuyruk JSON'u durumların tek kaynağıdır; EXECUTION_QUEUE.md aynı kaynaktan
üretilir. Özel hazırlık veya yerel derleme kabul edilmiş özellik sayılmaz.

| Alt iş | Şu anki durum | Kanıt / sıradaki somut kapı |
| --- | --- | --- |
| F60 RI5 launch/resume ve strict paket kimliği | Commit edildi, pushlandı; yeni runtime hatası açık | 79506adae koşusu ilk görüntü/nonzero ses sonrasında ownedInputEffects touch_ready ACK beklerken başarısız; production XI2 gözlemcisi gerçek disposable Linux probe ile inceleniyor |
| F62 mikrofon4 ve SAF grant5 | Commit edildi, pushlandı | 06ef24fae / 0cb84d079 yerel native/Flutter/AndroidTest kanıtları; gerçek dosya aktarımı veya Gateway kabulü değildir |
| F62 audio/mic effect-control | Commit edildi, pushlandı; yeni host hatası açık | f201ecf9b; arm64 actual APK geçti, x86 host control sıra gözlemi reddedildi. Ajan exact source poll/read/consume yarışını dar inceliyor |
| F62 SAF mirror ve kalıcı aktarım günlüğü | Özel kaynak dondu; root actual Robolectric 14/14 geçti | 0600 dosyalar, birleşik kota, kalıcı explicit Save/UNKNOWN/deadline. Gerçek DocumentsProvider etkisi ve MethodChannel entegrasyonu açık |
| F62 gerçek dosya kanalı kotası | Özel kaynak dondu; actual Android derlemesine alındı | Mac effect/ASAN/UBSAN/TSAN kapıları 4/4; proc-FD inode pin, 32 dosya/256 MiB/1 GiB, read/browse/mutation guard. Linux proc ve Android kanal etkisi açık |
| F62 native v5 yaşam döngüsü | Özel kaynak dondu; actual ABI derlemesi sürüyor | Java exact-source 5/5 + GlobalApp 3/3; stale callback ve same-thread drain çitleri. Root gerçek NDK'da bulunmayan drive settingini pinned upstream yoluyla düzeltti; actual çift ABI paket/host kabulü sırada |
| F62 Flutter schema6 ve Core profili | Özel hazırlık; gerçek uygulamaya bağlanıyor | İzole Flutter 15/15, Core 19/19; mevcut decoder/MethodChannel/controller/Save/Gateway vault bağlantısı ve root birleşik doğrulama açık |
| F62 RD Gateway | Özel consumer ve çalıştırılabilir fixture dondu | Ayrı pin/parola, direct-target engeli, tek hedef allowlist; fixture controller 8/8. Gerçek Linux Go/PAM/netns ve Gateway→target tüneli kabulü henüz yok |
| FINAL.FUNCTION teslimi | Açık | Tüm yazılım maddeleri tam kabul ve bağımlılık kanıtlarıyla onaylanacak; final dal HEAD required CI yeşil olacak; sonra main merge ve ancestry/içerik doğrulaması |
| FINAL.UI başlangıcı | Bekliyor | Yukarıdaki kabul ve merge doğrulanmadan başlamaz. Güncel main'den ayrı tek dal kullanılacak |

Üç ajan ayrı kaynakları hazırlıyor: drive/native yaşam döngüsü incelemesi;
SAF/Flutter bağlantısı; Gateway/effect-control incelemesi. Root kuyruk,
entegrasyon, native C, gerçek derleme ve Git'i yönetiyor. İkinci final çalışılmıyor.

F60 yeni terminal hata nedeniyle yeniden aktif; F62 de aktif. **69 iş / 58
seçili özellik CI bekliyor**. Kabul **35/127 (%27,6)** ve **3/63 (%4,8)**
değişmedi. [Yeni exact hata kanıtları](native-strict-7950-f201-failure-2026-10-03.md).

Eski CI hataları korunuyor; aynı kaynak körlemesine rerun edilmiyor. Fiziksel
cihaz/gerçek ev servisi/hesap kapıları MANUAL kayıtlarında açık kalır. Probe,
controller testi veya private port, özellik kabulünün yerine geçmez.
