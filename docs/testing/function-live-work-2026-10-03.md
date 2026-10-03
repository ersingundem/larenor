# FINAL.FUNCTION — görünür alt işler, 3 Ekim 2026

Bu tablo ürün dalına alınmış çalışmalar ile özel hazırlıkları ayırır. Özel
hazırlıklar tamamlanmış özellik veya CI kabulü sayılmaz. Kuyruk JSON'u durumların
tek kaynağıdır; EXECUTION_QUEUE.md aynı kaynaktan üretilir.

| Alt iş | Şu anki durum | Kanıt / sıradaki somut kapı |
| --- | --- | --- |
| F60 RI5 launch/resume anahtar sahipliği | Commit edildi, pushlandı | Actual v5 çift ABI paket ve yerel kapılar geçti; 9a85dc1f kaynak dilimi |
| F60 strict paket kimliği | Commit edildi, pushlandı; CI bekliyor | 79506adae, root 86/86; [Sunshine37128656191](https://github.com/ersingundem/larenor/actions/runs/37128656191) exact kaynakta gerçek yayın çalıştırıyor; henüz runtime kabulü yok |
| F62 mikrofon4 ve SAF grant5 | Commit edildi, pushlandı | 06ef24fae / 0cb84d079; native, Flutter ve AndroidTest yerel kanıtları mevcut; grant kaydı dosya aktarımı değildir |
| F62 tanıdan bağımsız audio/mic arm | Commit edildi, pushlandı; runtime sonucu bekliyor | f201ecf9b; root 78/78 ve actual AndroidTest derlemesi geçti; [RDP37128695877](https://github.com/ersingundem/larenor/actions/runs/37128695877) arm64 APK derlemesi geçti, x86 host kapısı sürüyor |
| F62 SAF mirror ve kalıcı aktarım günlüğü | Özel kaynak hazır; değişmiş kaynak doğrulaması sırada | Önceki kaynak 9/9 Robolectric geçti. Yeni kaynak: 0600 dosyalar, iki yön toplam kotası, açık Save ile boş transferin kalıcı kapanışı, UNKNOWN sonrası yeni dizin engeli ve sealing boyunca deadline; yeni test koşusu gerekli |
| F62 gerçek dosya kanal kotası | Ajan geliştiriyor | FreeRDP drive create/write/resize/rename/delete sınırları; birleşik 32 dosya, dosya başına 256 MiB, toplam 1 GiB; actual ABI derlemesi ve dosya etkisi kabulü henüz yok |
| F62 native v5 yaşam döngüsü | Root ve ajan düzeltiyor | İnceleme legacy free/drained free yarışı, kapanan context'e config erişimi ve path/inode değişim aralığı buldu; bu hatalar kapanmadan paket ürün dalına alınmayacak |
| F62 Flutter schema6 ve Core profili | Özel hazırlık; gerçek uygulamaya bağlanıyor | Ajanın izole Flutter kapısı 15/15, Core profil kapısı 19/19; root bağımsız birleşik doğrulaması ve mevcut decoder/MethodChannel/route bağlantısı açık |
| F62 RD Gateway | Özel consumer ve izole fixture hazırlığı | Ayrı pin/kimlik bilgileri, direct-target engeli ve tek hedef allowlist; gerçek Gateway→target tüneli kabulü henüz yok |
| FINAL.FUNCTION teslimi | Açık | F60/F62 tam yazılım kabulü ve son dal HEAD zorunlu yeşil CI; sonra mevcut dal main'e merge, ardından güncel main'den tek FINAL.UI dalı |

Üç ajan birbirinden ayrı kaynakları hazırlıyor: drive kanalı; SAF/Flutter
bağlantısı; Java oturum/Gateway güvenliği. Root kuyruk, entegrasyon, native C,
derleme ve Git'i yönetiyor. İkinci final maddesi çalışılmıyor.

F60 aktif kaynak geliştirmesi tamamlandığı için CI bekleyenler tablosuna taşındı.
Yeni gerçek CI hatası çıkarsa yeniden çalışılıyor durumuna döner. F62'de açık
ürün geliştirmesi bulunduğundan aktif kalır. CI bekleyen sayaç 70 iş / 59 seçili
özelliktir; kabul sayacı **35/127 (%27,6)** ve **3/63 (%4,8)** değişmedi.

Eski CI hataları silinmedi veya aynı kaynakla körlemesine yeniden başlatılmadı.
Yerel testler gerçek host, cihaz, sağlayıcı ve final dal HEAD kabulünün yerine
geçmez. Tamamlanma için dummy veri veya hazır private port yeterli değildir.
