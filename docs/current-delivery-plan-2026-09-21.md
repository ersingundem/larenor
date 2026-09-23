# Larenor — güncel teslim sırası (24 Eylül 2026)

Bu sayfanın birleşmiş kod kanıtı `origin/main` **`8f2ce21b`** kaynağına kadar
S08.8, S09.1 ve K03 teslimlerini kapsar. Canlı kabul sayacı
[`execution-queue.json`](execution-queue.json) ile
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

## Kanıtı açık kalan sınırlar

1. **S08.8:** Core playback/worker, exact cache sözleşmesi, açık eski Jellyfin
   geçişi ve merkezi medya ile Music Assistant ürün E2E'leri main'de. Yazılım
   kapanışı için aktif direct medya UI/runtime tüketicileri kaldırılmalı ve
   merkezi browse/recent/resume eşliği tamamlanmalı. Gerçek HomePod/Cast/Apple
   TV ayrı `MANUAL.MEDIA` kapısıdır. S08.11 ve B3 kapanışı S08.8'e bağlıdır.
2. **S09.1:** Kalıcı kurulum otoritesi, Docker pause/adaptör ve generation-bound
   read-only/COW capture lease main'de. Privileged Linux capture engine,
   amd64/arm64 native kabulü ve DB/ayrı anahtar/yapılandırma/bileşen
   veri+sürümlerinin aynı tutarlı generation içinde arşiv kanıtı kalır.
3. **S09.2–S09.3:** S09.2 yanlış parola, kesik, bozuk imzalı ve uyumsuz
   yedeklerde sıfır kısmi kabul ile boş izole ortamda anahtar/veri/bağlantı geri
   okuma, yeniden başlatma ve kurtarma zincirini; S09.3 amd64/arm64 temiz
   kurulum/yükseltme, Client geri yükleme sınırı ve bileşen sağlık kanıtını,
   üretim otomasyonu veya ev cihazı çalıştırmadan kapatmalı.
4. **Kiosk:** K03 native SAF indirmesi, external action ve renderer ölüm
   yaşam döngüleri main'de. Allowed subresource cross-origin redirect ve
   WebSocket/worker egress'i için owned, bounded network transport açık;
   fiziksel Android/DeX/OEM, DPC, force-stop ve çevre birimi kanıtları manuel.
5. **F01–F63:** Birleşen özellik dilimleri Core otoritesi ve tablet yüzeyleri
   sağlıyor; üretim sağlayıcıları, gerçek donanım veya native motor eksik olan
   görevler pending kalır. DeX ikinci ekran gerçek ayrı Flutter görevini,
   F60 paketlenmiş yayın motorunu, F46–F49 üretim adaptörlerini bekliyor.
6. **Son ürün:** Ortak tablet tasarım/performans/güvenlik denetimi, gerçek tablet
   ekran görüntüleri, README, imzalı güncelleme ve CasaOS/Proxmox kurulumu son
   yazılım kapılarından sonra yapılır.

## Sıradaki üç bağımsız yazılım hattı

| Hat | İlk dar teslim | Tamamlanma kapısı |
| --- | --- | --- |
| A — S08.8 | Merkezi browse/recent/resume eşliğini tamamla; dashboard, hub, arama, casting, hedef ve ayar yüzeylerindeki aktif direct Jellyfin/MA runtime tüketicilerini devreden çıkar. | Client ayrı adres-token istemez; Core route değişimi/logout/restart E2E eski veriyi göstermez; gerçek alıcılar ayrı MANUAL.MEDIA |
| B — S09.1 | Capture lease'i kullanan privileged Linux engine'i ve tam arşiv generation'ını uygula. | DB/anahtar/yapılandırma/bileşen veri+sürümü aynı generation; işlem kesilme/şema/sürüm, amd64/arm64 native kabul ve yedek izolasyonu |
| C — K03.remaining | WebPanel için same-origin redirect takipli owned/bounded transport kur; WebSocket ve worker egress'ini fail-closed sınırla. | Subresource redirect/iframe adversarial Android testleri, mevcut origin ve sır sızıntısı kapıları; fiziksel Android/DeX/OEM ayrı manuel kapıda kalır |

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
