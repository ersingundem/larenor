# Larenor — güncel teslim sırası (23 Eylül 2026)

Bu sayfa `origin/main` **`c9e7cc08`** ve GitHub'daki yalnız açık **PR #447** görünümünü
kaydeder. Canlı kabul sayacı [`execution-queue.json`](execution-queue.json) ile
üretilen [`EXECUTION_QUEUE.md`](EXECUTION_QUEUE.md) içindedir: **26/125 iş**,
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
- PR #439, #443, #444, #445 ve #446 exact-head review/CI sonrasında main
  `c9e7cc08` zincirine girdi. F28, S08.8, F24, F31 ve S09.1 tam kuyruk
  bağımlılıkları veya kalan acceptance sınırları nedeniyle `pending` kaldı.
- PR #447 bounded managed-volume provider dilimi olarak açıktır; henüz birleşmiş
  veya kabul edilmiş sayılmaz. Eski bağımlı PR zincirleri aktif teslim planı
  değildir.

## Kanıtı açık kalan sınırlar

1. **S08.8:** Üye kataloğu Core'a taşındı; eski ayarların açık geçişi,
   provider/player/queue yolu ve tuple/resource/sürüm/TTL/kota bağlı kalıcı
   cache kabulü hâlâ tamamlanmalı. S08.11 ve B3 kapanışı buna bağlıdır.
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
| A — S08.8 | Eski medya/müzik ayarlarını açık onayla Core kaynaklarına ve typed cache kimliklerine geçir. | Provider/player/queue, authority kaybı, başka Core ve TTL/kota E2E |
| B — S09.1 | Açık PR #447'nin provider dilimini incele; journal-bound gerçek capture ve restore zincirini sürdür. | Engine/journal authority, restore/rollback, kesinti ve büyük hacim iki mimari kabulü |
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
