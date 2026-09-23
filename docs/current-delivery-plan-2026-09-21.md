# Larenor — güncel teslim sırası (23 Eylül 2026)

Bu sayfa `origin/main` **`70c667b5`** ve GitHub'daki **0 açık PR** görünümünü
kaydeder. Canlı kabul sayacı [`execution-queue.json`](execution-queue.json) ile
üretilen [`EXECUTION_QUEUE.md`](EXECUTION_QUEUE.md) içindedir: **23/125 iş**,
**0/63 seçili özellik**. PR #328, 28 kaynak PR'ın exact head commitlerini tek
birleşim zincirinde korudu ve bütün zorunlu kontroller geçtikten sonra main'e
girdi. Birleşmiş kod, kuyruktaki bütün kabul ölçütlerini kendiliğinden kapatmaz.

| Durum | Anlamı | Sayaç etkisi |
| --- | --- | --- |
| `PENDING` | Kod, bağımlılık veya kabul kanıtı eksik. | Yok |
| `AWAITING_CI` | Tam kabul dilimi kendi exact head CI'ını bekliyor. | Yok |
| `NEEDS_USER` | Gerçek tablet, ağ, alıcı, sensör veya ev kurulumu gerekiyor. | Yazılım kabulünün yerine geçmez |
| `DONE` | Bütün ölçütler, test/review/CI ve bağımlılıklar doğrulandı. | Yalnız ilgili iş |

## Birleşik kapanış kanıtı

- [PR #328](https://github.com/ersingundem/larenor/pull/328), 21 Eylül 2026'da
  merge commit `70c667b5` ile birleşti. Kaynak PR #274, #275, #276, #277,
  #279, #281, #282, #283, #284, #286, #287, #289, #290, #291, #292, #293,
  #294, #295, #296, #298, #300, #306, #311, #313, #316, #317, #320 ve #327
  bu ancestry içinde kapandı.
- Exact head `e154242d` üzerinde Flutter statik analiz ve dört test shardı,
  dört Server shardı ile aggregate kapılar, API 35 E2E, debug APK, Security,
  SSH ve medya bileşenlerinin iki mimarili native kabulü geçti.
- Aile panosu v2 şifreli yedeğe eklendi; v1 geri yükleme uyumluluğu ve kesilmiş
  v2 geri yükleme kurtarması test edildi.
- GitHub'da açık PR yok. Eski bağımlı PR zincirleri ve conflict listeleri artık
  aktif teslim planı değildir.

## Kanıtı açık kalan sınırlar

1. **S07.4:** Client'ın yalnız medya/sağlayıcı ayarlarını yönetmesi, doğrulanmış
   entegrasyon ile çalışan sürecin ayrılması, eksik yeteneğin açık görünmesi ve
   iki mimarili restart içeren çapraz servis E2E tek kapanışta kanıtlanmalı.
2. **S09.1–S09.3:** DB, ayrı anahtar, yapılandırma, bileşen verisi/sürümleri,
   temiz kurulum/yükseltme ve geri yükleme zinciri aynı sözleşmede tamamlanmalı.
   Mevcut aile panosu/boş Core restore dilimleri bu kapsamın tamamı değildir.
3. **Kiosk:** WebPanel ileri işlemleri, ortam içerik listeleri, eşleştirilmiş
   remote/MQTT, sensör ve çevre birimi yaşam döngüsü kendi kabul matrislerine
   göre kapanmalı. DPC/OEM, force-stop ve gerçek çevre birimi kanıtları manuel.
4. **F01–F63:** Birleşen özellik dilimleri Core otoritesi ve tablet yüzeyleri
   sağlıyor; üretim sağlayıcıları, gerçek donanım veya native motor eksik olan
   görevler pending kalır. DeX ikinci ekran gerçek ayrı Flutter görevini,
   F60 paketlenmiş yayın motorunu, F46–F49 üretim adaptörlerini bekliyor.
5. **Son ürün:** Ortak tablet tasarım/performans/güvenlik denetimi, gerçek tablet
   ekran görüntüleri, README, imzalı güncelleme ve CasaOS/Proxmox kurulumu son
   yazılım kapılarından sonra yapılır.

## Sıradaki üç bağımsız yazılım hattı

| Hat | İlk dar teslim | Tamamlanma kapısı |
| --- | --- | --- |
| A — S07.4 | Medya ve sağlayıcı ayarlarında capability/readback durumlarını tek Client sözleşmesinde doğrula. | Çapraz servis E2E, restart ve iki mimarili exact-head CI |
| B — S09.1 | Yedek manifestini DB, ayrı anahtar, config, bileşen verisi ve sürüm uyumuyla genişlet. | Wrong-key/tamper, kesinti sınırı, şema uyumu ve exact-head CI |
| C — K03.remaining | WebPanel upload/download, pop-up/intent ve renderer kurtarma sınırlarını tamamla. | Origin/redirect/iframe, auth/sertifika, sır sızıntısı ve Android CI |

Hatlar farklı dosya sahipliklerinde ilerler. Her hat önce eksik kabul ölçütünü
başarısız testle sabitler, yalnız ilgili testleri yerelde çalıştırır ve büyük
teslim sonunda exact-head zorunlu CI kullanır. Aynı başarısız koşu körlemesine
yeniden başlatılmaz; iptal edilmiş veya eski SHA'ya ait sonuç kabul sayılmaz.

## Fiziksel ve kullanıcı katılımlı kapılar

- CasaOS/Proxmox tek Larenor kurulumu ve aynı imzalı Client güncellemesi.
- Huawei MatePad, Android tablet, Samsung DeX, klavye ve TalkBack matrisi.
- Gerçek Home Assistant/ağ/altyapı servisleri; yalnız salt okunur doğrulama.
- Spotify, Apple Music, YouTube Music, HomePod, Cast ve Apple TV oynatma.
- Sağlık/tartı sağlayıcı izinleri, kiosk DPC/OEM ve çevre birimleri.
- Netelsan Algan 7 elektronik köprüsü ve diğer donanım özellikleri.

Canlı Home Assistant erişiminde yalnız okuma yapılır. Sunucu restore, cihaz
yazma veya elektronik kapı eylemleri test kanıtından hareketle canlı ortamda
kendiliğinden çalıştırılmaz.
