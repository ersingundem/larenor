# Larenor — güncel teslim sırası (24 Eylül 2026)

Bu sayfanın birleşmiş kod tabanı `origin/main` **`db05532b`**, K07 kabul
kaynağı **`0a6c2b29`** commitidir. S08.8, K07, S09.1 ve K03 teslimlerini kapsar.
Canlı kabul sayacı
[`execution-queue.json`](execution-queue.json) ile
üretilen [`EXECUTION_QUEUE.md`](EXECUTION_QUEUE.md) içindedir: **29/125 iş**,
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
- PR #439, #443, #444, #445, #446 ve #447 exact-head review/CI sonrasında main
  `36e05f9a` zincirine girdi. F28, S08.8, F24, F31 ve S09.1 tam kuyruk
  bağımlılıkları veya kalan acceptance sınırları nedeniyle `pending` kaldı.
- PR #447 bounded managed-volume provider dilimini birleştirdi; S09.1'in
  tutarlı ve izole yedek alma kapıları açık kaldı. Eski bağımlı PR zincirleri
  aktif teslim planı değildir.
- PR #450 durable snapshot kaynaklarını exact kurulum otoritesine bağladı; PR
  #452 exact Docker Engine inspect/pause/unpause ve belirsiz-etki uzlaştırmasını
  main `8cfe43ef` içine aldı.
- PR #451 tek kullanımlık Core playback intent/receipt sözleşmesini; PR #453
  açık ve erişilebilir eski Jellyfin tercih geçişini main'e aldı. #455
  güncel yetki doğrulamalı Client önbelleklerini `c8088367` ile birleştirdi.
  #454 yönetilen Jellyfin worker'ını, işlem öncesi/sonrası kesinliği ve stream
  temizliğini 41 exact CI kontrolünden sonra `a9bf847b` ile main'e aldı.
- PR #456 güncel teslim kanıtını `7d9bee7c` ile sabitledi. PR #457–#462
  current-head CI ve API 35 emülatör kapısından sonra main'e girdi: K03 native
  SAF/renderer yaşam döngüsü `8fdfc36e`, exact sürümlü medya cache sözleşmesi
  `31b78659`, merkezi medya ve müzik ürün E2E'leri `ff8ebf10`/`9286cebf`,
  izole capture lease'i `9ccd6fe4`, açık Jellyfin bağlantı geçişi `8f2ce21b`.
  Altı kaynak/squash stable patch-id eşitliği, main ancestry'si ve branch
  temizliği ayrı doğrulandı; açık PR kalmadı.
- PR #474 exact `ac8e1af6` kaynağında anonymous owned alt-kaynak transportu,
  her redirectte exact-origin doğrulamasını ve document-start dynamic-egress
  kapısını API 35 matrisiyle tamamladı. Android Build `35941771379` ve Security
  `35941771192` aynı exact kaynakta geçti; kaynak `7211a6ff` olarak birleşti.
  K03.remaining yazılım kabulü kapandı ve sayaç 27/125 oldu.
- PR #480 exact `ff55f514` kaynağında Core medya yüzeylerindeki direct provider
  kurulumunu kapattı ve browse/recent/resume restart, logout ve Core-switch
  yolculuklarını gerçek loopback ile doğruladı. Android Build `35950583150`,
  Security `35950582810` ve bağımsız P1/P2 incelemesi geçti; S08.8 yazılım
  kabulü kapandı ve sayaç 28/125 oldu. Fiziksel alıcılar `MANUAL.MEDIA`'dır.
- PR #481 exact `0a6c2b29` kaynağında secure enrollment/runtime owner,
  TLS MQTT SUBACK/PUBACK ve replay/rate/scope sınırlarını native lock ile Dart
  refresh/profile komutlarına bağladı. Android Build `35953409201`, Security
  `35953408908` ve bağımsız P1/P2 review geçti; K07 yazılım kabulü kapandı ve
  sayaç 29/125 oldu. Huawei/DeX/TalkBack/OEM/DPC, gerçek broker kurulumu ve cihaz
  ölçümleri MANUAL kalır.

## Kanıtı açık kalan sınırlar

1. **S09.1:** Kalıcı kurulum otoritesi, Docker pause/adaptör ve generation-bound
   read-only/COW capture lease main'de. Privileged Linux capture engine,
   amd64/arm64 native kabulü ve DB/ayrı anahtar/yapılandırma/bileşen
   veri+sürümlerinin aynı tutarlı generation içinde arşiv kanıtı kalır.
2. **S09.2–S09.3:** S09.2 yanlış parola, kesik, bozuk imzalı ve uyumsuz
   yedeklerde sıfır kısmi kabul ile boş izole ortamda anahtar/veri/bağlantı geri
   okuma, yeniden başlatma ve kurtarma zincirini; S09.3 amd64/arm64 temiz
   kurulum/yükseltme, Client geri yükleme sınırı ve bileşen sağlık kanıtını,
   üretim otomasyonu veya ev cihazı çalıştırmadan kapatmalı.
3. **Kiosk manuel sınırı:** K03 native SAF, external action, renderer yaşam
   döngüsü, anonymous owned alt-kaynak transportu ve document-start dynamic
   egress; K07 secure enrollment, TLS MQTT ve bounded native/profile komutları
   yazılım kabulünü tamamladı. Fiziksel Android/Huawei/DeX/TalkBack/OEM, DPC,
   gerçek broker kurulumu, force-stop ve çevre birimi kanıtları ayrı manuel
   kapıdır.
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
| A — S09.1 | Capture lease'i kullanan privileged Linux engine'i ve tam arşiv generation'ını uygula. | DB/anahtar/yapılandırma/bileşen veri+sürümü aynı generation; işlem kesilme/şema/sürüm, amd64/arm64 native kabul ve yedek izolasyonu |
| B — S09.2 | İzole restore staging, post-commit authority/deadline reconciliation ve durable restart cleanup zincirini tamamla. | Yanlış parola, kesik/bozuk imza, sürüm/şema uyuşmazlığı ve kesinti sıfır kısmi kabul; S09.3 clean-install ayrı kalır |
| C — S09.3 | Temiz kurulum/yükseltme ve Client geri yükleme sınırını exact S09.1/S09.2 çıktılarıyla bağla. | amd64/arm64 temiz kurulum, sürüm yükseltme ve Client preflight aynı imzalı artefaktlarla kanıtlanır; fiziksel ev cihazı yazımı yapılmaz |

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
