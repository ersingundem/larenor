# S06.3d — Yönetilen volume gözlemi

6 Eylül 2026. `codex/managed-volume-observation`, `4bc79dc` tabanından
ayrıldı. Üretim kodu `74f436c`; bağımsız kaynak incelemesi temiz.

Bu dilim saf ve henüz bağlanmamış bir Engine yanıt denetimidir. Network veya
host dosyası açmaz, kurulum endpoint'i, create/delete isteği ya da kalıcı
journal eklemez. `installAvailable=false` korunur. Volume kimliği, doğrulanmış
oluşturma, münhasır sahiplik, container'a bağlama veya yazılabilirlik yetkisi
olarak kullanılmaz.

## Davranış

`volume_resources.py`, tam `VolumeStoragePlan`, stack, katalog ve worker
politikasını her çağrıda yeniden türetir. Seçilen yedi appdata hedefinden biri,
ayrı volume journal kimliği ve ownership nonce ile özel bir beklentiye bağlanır.
Bu kimlikler mevcut inode journal'ından alınmaz; yeni kalıcı volume journal'ı
henüz uygulanmadığı için burada yalnız güvenilir süreç içi girdilerdir.

Üretilen tek hedef `/v1.47/volumes/{üretilmiş-ad}` biçimindedir. Client'tan
volume adı, URI, driver seçeneği veya etiket alınmaz. Core, ev, hazırlık,
resource, operation, installation, service, child/stack/volume plan, katalog,
worker politikası, journal, nonce ve specification özeti toplam 17 exact
etiketle karşılaştırılır. Aynı ad, eksik/ek veya farklı etiketler kabul edilmez.

Yanıtın HTTP 200 ve JSON olması; driver/scope `local`, Options null/boş map
olması gerekir. Zorunlu alanlar default edilmez. Yabancı driver seçenekleri,
ClusterVolume, dolu Status ve inspect dışındaki UsageData reddedilir. Bilinmeyen
alanlar bu dar ilk sözleşmede uyumluluk hatasıdır. Temel alanlar ve API sürümü
[Moby 27.5.1 / Engine 1.47 şemasına](https://raw.githubusercontent.com/moby/moby/v27.5.1/api/swagger.yaml)
göre kontrol edildi. Bu kaynak incelemesi gerçek hedef Engine testi değildir.

64 KiB body, derinlik/node/string sınırları, strict UTF-8, yinelenen JSON
anahtarları, geçersiz sayılar ve belirsiz/eksik HTTP framing denetlenir.
Host `Mountpoint` yalnız sınırlı düz metin olarak doğrulanıp atılır; sonuçta,
hata mesajında veya repr'de bulunmaz. Dönen immutable gözlem yalnız
`labels_matched` durumunu, üretilmiş ad/resource/plan kimlikleri ve label
özetini taşır. Oluşturma yanıtı 201 veya bulunamadı yanıtı 404 bu gözlemin
yerine geçmez. Transport, gerçek request/response ve daemon bağını daha sonra
ayrıca kanıtlamalıdır. Başka bir Docker yöneticisi aynı ad/etiketleri
kopyalayabileceği için bu gözlem değiştirilemez bir Engine kimliği değildir.

## Test kanıtı

| Aşama | Sonuç |
| --- | --- |
| `d2c8b79` RED | Güvenli eksik uygulama: 7 PASS, 7 FAIL, binding kurulumunda 79 ERROR. Import/derleme hatası değildir; setup hataları başarılı negatif test sayılmadı. |
| `74f436c` GREEN | 93 odaklı test PASS. |
| Son pozitif framing testleri | 95 odaklı test, toplam **282 ilgili test PASS**, 9,39 saniye. |
| Kapsam | Yeni modül **124/124 satır, 24/24 dal: %100**. Tüm Server kapsamı değildir. |
| Bağımsız inceleme | `74f436c` kaynak ve testleri okundu; somut ek düzeltme bulunmadı. |

İlgili küme volume observation/plan, mevcut kaynak planı ve network response
sözleşmesidir. Aynı testler ayrı toplamlara eklenmez. Testler gerçek Core,
Docker/CasaOS veya ev ağı yerine sentetik Engine byte'ları kullanır. Host
dosyası, socket ve süreç başlatma testte yasaklanarak saf davranış doğrulanır.

Çalıştırılan komut: Server dizininde `pytest -o addopts='' -q
tests/test_volume_resources.py tests/test_volume_plan.py
tests/test_resource_plan.py tests/test_network_resources.py`; coverage aynı
komutun `--branch --source=larenor_server.plugins.volume_resources` koşusudur.
Özel loglar: `/private/tmp/larenor-volume-observation-red.log`,
`/private/tmp/larenor-volume-observation-green.log` ve
`/private/tmp/larenor-volume-observation-final-related.log`.

## Sonraki bağımlılıklar

Volume'a özel durable intent/reconcile kaydı; gerçek Engine'de iki mimarili
UID/başlangıç verisi doğrulaması; güncel admin yetkisi ve journal ile tek
create/yeniden inspect bağlantısı; ardından container mount, sağlık ve otomatik
API eşlemesi. Native host dizini yolunun güvenlik kapıları ve kullanıcı medya
kütüphanesi değişmedi. Bu dilim tek başına S06.3d kabulünü artırmaz.
