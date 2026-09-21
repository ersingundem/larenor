# Larenor — güncel teslim sırası (21 Eylül 2026)

Bu sayfa, `origin/main` **`e81ea793`** ve GitHub'daki **44 açık PR**
görünümünün 21 Eylül 2026 anlık görüntüsüdür. Canlı kabul sayacı
[`execution-queue.json`](execution-queue.json) ile üretilen
[`EXECUTION_QUEUE.md`](EXECUTION_QUEUE.md) içindedir: **22/125 iş**, **0/63
seçili özellik**. Açık PR, yerel test veya auto-merge ayarı kabul değildir.
Bir iş yalnız kuyruktaki bütün ölçütler, zorunlu exact-head CI ve bağımlı
birleşimler kanıtlandığında `done` olur. Fiziksel kapılar ayrıca MANUAL kalır.
PR ve check sayıları anlık görüntüdür; canlı durum için [açık PR'ları](https://github.com/ersingundem/larenor/pulls)
ve her PR'ın son HEAD check'lerini açın. GitHub `BLOCKED`, yalnız bekleyen
zorunlu check nedeniyle de görünebilir; ürün hatası anlamına gelmez.

| Durum | Anlamı | Sayaç etkisi |
| --- | --- | --- |
| `PENDING` | Kod veya öncül henüz açık; kabul kanıtı eksik. | Yok |
| `CI` | PR açık; kendi exact head'i ve gerekli öncül PR'lar bekleniyor. | Yok |
| `MANUAL` | Gerçek tablet, ağ, alıcı, sensör veya ev kurulumu gerekiyor. | Yazılım kabulünün yerine geçmez |
| `DONE` | Kuyruk ölçütleri, test/review/CI ve birleşim doğrulandı. | Yalnız ilgili iş |

## Birleşim sırası ve bağımlılıklar

1. **S09 yedek/kurtarma zinciri — CI.** #302 Core capture sözleşmesi → #315
   şifreli bundle → #316 boş Core'a journal'lı restore → #317 iki mimarili
   Server image restore kabulü → #313 Android'de salt okunur backup readiness.
   #315 ve #316 güvenlik incelemesindeki iki P2 düzeltme, alt dallara aynı
   içerikle taşındı. #313 yalnız readiness gösterir; Client'tan yedek indirme,
   açık onaylı restore UX, kurulum/yükseltme ve bileşen volume verileri ayrıca
   kabul gerektirir. S09.1–S09.3 **PENDING/CI**; B4 **0/3** kalır.
2. **Kiosk temel zinciri — CI/PENDING.** #303 ortak test güvenilirliği; #304 WebPanel
   renderer/transfer; #306 eşlenmiş uzaktan kumanda ve MQTT; #308 watchdog ve
   içeriksiz kullanım ölçümü; #309 sınırlı remote-view yetkisi; #310 sensör
   oturumu; #311 kiosk gezinmesi; #312 çevre birimi sınırı; #320 bunun tablet
   görünümü; #314 filo profili dry-run/rollout. #305 ortam video/PDF/web
   listeleri ve #319 HID girdi oturumu ayrı PR'lardır. #318 ortak Core kaynak
   E2E görünürlüğünü düzeltir. #307 K08 native köprü temelini main'e getirdi;
   K08'in WebPanel/K07 uçtan uca kullanıcı kabulü hâlâ kuyrukta `pending`.
   K11 için #320, #312'den sonra; K13 için K07,
   K12 ve F53 yazılım kapıları kanıtlanmadan sıra atlanmaz. DPC/OEM,
   force-stop sonrası yeniden başlatma, gerçek çevre birimi ve sensör davranışı
   **MANUAL** kalır.
3. **Özellik entegrasyonları — CI/MANUAL.** Açık F31/F35–F60 paketleri Core
   otoritesi, kalıcı durum, Android tablet ekranı ve fail-closed readback
   dilimlerini taşıyor. Her F görevi kendi kuyruk kabulünde değerlendirilir;
   PR'ları topluca 63 özelliği tamamladı diye sayılmaz. Özellikle kamera,
   enerji/inverter, varlık algısı, e-paper, IR/RF ve DeX çift ekranının gerçek
   donanım kanıtı ayrı kalır. #279 F58'de kullanıcı kaynaklı ACK yalnız
   `acknowledged` olabilir; eşlenmiş cihaz imzası ve fiziksel görüntü kanıtı
   olmadan `verified` kabul edilmez.
4. **S07.4 ve S08.10 — CI.** Tek kurulum/ayar kabulü #300 ve bounded ürün
   transfer yazılım kapanışı #301 ana dala girip exact-head kapıları geçmeden
   ilgili kuyruk satırı kapatılmaz. Medya abonelikleri, HomePod/Cast oynatma,
   Home Assistant, Keenetic ve Proxmox canlı sonuçları **MANUAL** kapılarındadır.

## Sıradaki çalışma adımları ve kapanış kapıları

1. **Ortak E2E tabanını sabitle.** #303 remount/klavye/transfer ve #318 Core
   resource görünürlüğü kendi exact HEAD'lerinde yeşil olup main'e birleşsin.
   Ardından yalnız bu ortak hatadan etkilenen #275, #287, #298 ve diğer ürün
   PR'larında güncel base ile seçici E2E doğrulansın. Eski iptal edilmiş run'lar
   ürün kusuru sayılmasın.
2. **S09'u alttan üste birleştir.** #302 → #315 → #316 → #317 → #313. Her
   basamakta base/head ve kayıp yanıt, yanlış anahtar, bozuk bundle, kesilen
   restore, journal/orphan stage temizliği sınansın. Component volume'leri,
   temiz kurulum/yükseltme ve Client açık onaylı geri yükleme bitmeden S09
   kapanmaz. Bir öncülde fix çıkarsa üst dalların exact HEAD'i yenilenir.
3. **S08.10 ve S07.4'ü bağımsız kabul et.** #301 sonrası queue/progress
   `23/125` ancak main'de merge ve tüm gerekli check'ler tamamlanınca yazılır.
   #300 için kurulum durumu, ayarlar, belirsiz sonuç ve gerçek paket yaşam
   döngüsü karşılaştırılır; tek başına yeşil bir API testi yeterli değildir.
4. **Kiosk bağımlılıklarını aç.** #304/#305 WebPanel ve ortam listeleri;
   #306 K07; #312→#320 K11; #308 K12; #314 K13 sırası korunur. K07,
   S08.10'a; K11, K08 tam kabulüne; K13, K07/K12/F53'e bağlıdır. Her PR
   birleşse bile kuyruktaki tüm K kabulü otomatik kapanmaz.
5. **Özellikleri tek tek doğrula.** F31/F35–F60 PR'ları için tam üç kullanıcı
   ölçütü, Core/Client yetki ve stale-readback sınırı, tablet EN/TR erişim
   matrisi ve ilgili servis/hardware MANUAL kanıtı ayrı dosyada izlenir.
   F58 radio teslimi, F56 IR/RF, F52 fiziksel DeX ve F47 inverter yazma
   kabulü gerçek cihaz olmadan kapatılmaz.
6. **Son ürün bütünlüğü.** Ortak tablet tasarım/performans/güvenlik ve
   cihazlar arası akış denetiminden sonra README kurulum adımları ve gerçek
   tablet ekran görüntüleri güncellenir. Son release imza, güncelleme,
   geri yükleme ve CasaOS/Proxmox kurulum kanıtına dayanır.

## İki PR hattının çalışma kuralı

- **Hat A:** S09 gibi tabanlı PR zincirlerinde önce en alt bağımlılığı temizler;
  sonraki dalı exact öncül HEAD'e taşır. Review düzeltmesi alt dalda çıkarsa
  test edilip sırayla üst dallara taşınır. Aynı dosyaya eşzamanlı yazılmaz.
- **Hat B:** Dosya çakışması olmayan kiosk/özellik PR'larının gerçek CI
  hatalarını düzeltir. Bağımsız yeşil PR'ları otomatik birleşmeye bırakır;
  bağımlı PR'larda base/head eşleşmesini ve merge-tree'yi denetler.
- Her hat yalnız değişen dosyaların hedefli testini yerelde çalıştırır.
  CI'da bir PR'ın kendi exact HEAD'i esastır; eski/cancelled çalıştırmalar
  veya sentetik merge checkout'taki eski ilerleme trailer'ları yeni ürün
  hatası gibi topluca rerun edilmez. Her düzeltme kanıtı ve PR durumu
  ilgili `docs/testing/` dosyasında tutulur.

## Sonraki kabul kapıları

| Kapı | Eksik kanıt | Statü |
| --- | --- | --- |
| S09.1 | Şifreli Core bundle CI; component-volume/sürüm kapsamı ve tek kurulum sözleşmesi | `CI` / `PENDING` |
| S09.2 | Boş hedef, wrong-key/tamper, restart ve journal recovery'nin image kabulü | `CI` |
| S09.3 | amd64/arm64 temiz kurulum + yükseltme + Client restore sınırı + bileşen sağlığı | `CI` / `PENDING` |
| K05/K11/K12/K13 | Bağımlı PR birleşimleri, exact CI, tablette EN/TR erişilebilirlik ve yetki/lifecycle | `CI` / `MANUAL` |
| F01–F63 | Her özellik için ayrı fonksiyonel kabul; uygun gerçek cihaz/servis ölçümü | `PENDING` / `MANUAL` |
| Son UI/README | Ortak tablet tasarımının son bütünlük incelemesi, tablet görüntüleri, kurulum/release kanıtı | `PENDING` |

Canlı Home Assistant erişiminde yalnız okuma yapılır. Sunucu restore veya
cihaz yazma eylemleri, bu planın test kanıtlarından hareketle canlı ortamda
kendiliğinden çalıştırılmaz.
