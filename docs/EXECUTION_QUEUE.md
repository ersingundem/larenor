# Larenor kalıcı yürütme kuyruğu

[JSON kayıt](execution-queue.json) tek iş kimliği, bağımlılık, durum ve kabul
kanıtını saklar. [PROGRESS](PROGRESS.md) güncel ürün özeti ve CI anlatımıdır;
bu kuyruk ayrıntılı yürütme sırasıdır. Uygulanmış kabulün kapsamı veya kaynak
plan değişirse iki belge birlikte güncellenir. 5 Eylül 2026 başlangıcında
S06.3a/3b, 483ec13 Linux Server ve güvenlik CI ile kabul edildi. S06.3c
imaj/journal bağlantısı sonraki CI paketini bekliyor; S08.1 yerel testi geçti ve CI bekliyor. S06.3d/e alt adımları sürüyor. F01–F63 yazılım teslimleri bekliyor. Önceki S06.1–2 ve
kalıcı Core/ev kimliği tekrar yapılacak iş sayılmaz.

Bu kayıt bir zamanlayıcı, agent başlatıcı veya işlem yetkisi değildir. Araç
hiçbir kod, shell, Docker, ağ ya da ev cihazı işlemi yürütmez; dosyaları veya
durumları değiştirmez. Kayıt restart/oturum değişiminden sonra okunabilir.
Devam eden yetkili çalışma, bir işin gerçek kabulü tamamlanınca kaydı günceller
ve sonraki bağımlılığı hazır işi ele alır. CI bekleyen veya kullanıcı gerektiren
bir dal, bağımsız ve hazır yazılım dallarını durdurmaz.

## Güncel kuyruk özeti

<!-- queue-summary:start -->
F01–F63 yazılım kapısı: **0/63** (fiziksel kabul ayrı). Kalan kuyruk: **2/125 iş kanıtla tamamlandı**.

Gruplar ve önceki kabul checkpoint’leri iş sayısına dahil değildir.

| Grup | İş | Biten | Çalışılan | CI | Kullanıcı |
| --- | ---: | ---: | ---: | ---: | ---: |
| B1 — Yönetilen bileşen yaşam döngüsü | 9 | 2 | 2 | 1 | 0 |
| B2 — Bütünleşik medya ve müzik | 4 | 0 | 0 | 0 | 0 |
| B3 — Merkezi kaynak, yetki ve olay sözleşmeleri | 11 | 0 | 0 | 1 | 0 |
| B4 — Yazılım yedekleme ve kurtarma temeli | 3 | 0 | 0 | 0 | 0 |
| B5 — Erken ortak tablet Client deneyimi | 2 | 0 | 0 | 0 | 0 |
| PRODUCT — Önceki ürün planının kalan yazılım işleri | 13 | 0 | 0 | 0 | 1 |
| POC — Erken donanım/motor fizibilite kayıtları | 5 | 0 | 0 | 0 | 5 |
| G01 — Güvenilir Core ve izlenebilir işlemler | 5 | 0 | 0 | 0 | 0 |
| G02 — Kurtarma, yedek koruması ve güç | 3 | 0 | 0 | 0 | 0 |
| G03 — Erken bildirim, tablet ve ev görünümü | 4 | 0 | 0 | 0 | 0 |
| G04 — AI ve denetlenebilir otomasyon | 8 | 0 | 0 | 0 | 0 |
| G05 — Genişletilebilirlik, destek ve birden fazla ev | 4 | 0 | 0 | 0 | 0 |
| G06 — Medya ve müzik | 10 | 0 | 0 | 0 | 0 |
| G07 — Aile ve ev yaşamı | 10 | 0 | 0 | 0 | 0 |
| G08 — Kamera ve olaylar | 5 | 0 | 0 | 0 | 0 |
| G09 — Enerji, iklim ve bahçe | 5 | 0 | 0 | 0 | 0 |
| G10 — Ağ, varlık algısı ve yeni cihazlar | 6 | 0 | 0 | 0 | 0 |
| G11 — Proxmox'tan bağımsız uzak erişim | 4 | 0 | 0 | 0 | 0 |
| FINAL — Bütün yazılım sonrası son frontend ve yayın | 5 | 0 | 0 | 0 | 0 |
| MANUAL — Kullanıcıyla son kurulum ve fiziksel kabul | 9 | 0 | 0 | 0 | 9 |

<!-- queue-summary:end -->

125 iş aynı eforu temsil etmez; bu toplam ürün tamamlanma yüzdesi değildir.
F01–F63 sayacı **yazılım kapısını** sayar. Gerçek cihaz, sağlayıcı hesabı ve
canlı ev kabulü `MANUAL.*` içinde ayrıca açık kalır. Önceki yaklaşık %65 ile
bu payda birleştirilmez; seçili 63 özelliğin bütün cihazlarda tamamlandığı
iddia edilmez. POC işi kapanması bağlı ürün özelliğini otomatik kabul etmez.

## Okuma ve devam etme

Repo kökünden, yalnız Python 3.9+ standart kütüphanesiyle:

```sh
python3 tool/execution_queue.py validate
python3 tool/execution_queue.py status
python3 tool/execution_queue.py next
python3 tool/execution_queue.py next --json
python3 tool/execution_queue.py render --group S06 --page-size 10
python3 tool/execution_queue.py render --group G06 --page 1 --page-size 5
python3 tool/execution_queue.py render --summary-only
```

`status` grup toplamlarını gösterir. `next` devam edenleri, CI ve kullanıcı
bekleyenleri ayrı listeler; sonra dosya sırasıyla en çok beş başlanabilir iş
verir (`--limit 1..50`). `--group` bütün alt grupları içerir. `render` varsayılan
20, en çok 50 satırlık sayfa üretir; gruplar tamamlanma toplamına ikinci kez
eklenmez. `--json` salt veri çıktısıdır. `--file` ayrı bir yerel kuyruk dosyasını
okur; varsayılan repo yolu çalışma dizininden bağımsızdır. Geçerli komut 0,
bozuk veri/seçenek 2 döndürür; hata çıktısı sabit kod içerir.

Kabulden sonra yetkili geliştirici JSON'daki ilgili işi elle günceller,
`validate` çalıştırır ve yukarıdaki özetin `render --summary-only` çıktısını
belgeye taşır. Araç JSON'a yazmaz. Yeni kapsam eklemek; kabul koşulu, kaynak
plan, bağımlılık ve gerekiyorsa sürümlü şema değişikliği gerektirir.

## Durum ve kanıt sözleşmesi

| Durum | Anlamı | Devam kararı |
| --- | --- | --- |
| `pending` | Planlı; uygulanmış kabul yok | Bütün başlangıç bağımlılıkları kapandıysa başlanabilir |
| `in_progress` | Gerçek çalışma sürüyor | Önce aynı işin yarım çalışmasını incele ve devam et |
| `awaiting_ci` | Yerel çalışma bitmiş olabilir, uzak kapı bekleniyor | Tam kaynak commit'inin koşumunu doğrula; eski yeşili kullanma |
| `needs_user` | Gerekli cihaz/hesap/manuel katılım eksik | `reason` zorunlu; bağımsız hazır işe geç, eksikliği gizleme |
| `done` | Bu işin tanımlı kapsamı kanıtla kabul edildi | Bağımlı işlere kapı açılır; fiziksel/global kabul çıkarılmaz |

Her görevde `scope`, kaynak belgeler, somut `acceptance` ve
`requiredEvidence` bulunur. Yazılım işi test + bağımsız inceleme + CI; manuel
kabul işinde manuel kayıt + inceleme istenir. `done` için `completionCommit`
tam 40 karakter küçük harf Git SHA'dır. Bütün kanıtlar aynı SHA'ya, tamamlanmış
ve başarılı sonuca bağlı olmalı; gereken her kanıt türü mevcut olmalıdır.
Başarısız/iptal/atlanmış veya henüz çalışan CI bu kapıyı geçmez.

Kanıt biçimi `kind/ref/commit/state/result/label` alanlarıdır. `ci` referansı
yalnız bu repodaki sayısal GitHub Actions run URL'sidir. Diğer kanıtlar repo
altındaki belge/test kayıtlarına referans verir; sır, ham çıktı veya komut
saklanmaz. Etiket somut test/inceleme/manuel kabulü anlatır. `state` yalnız
`queued`, `in_progress`, `completed`; sonuç tamamlanmamış CI'da null,
tamamlanmış kayıtta `passed`, `failed`, `cancelled`, `skipped` olabilir.
GitHub'un success sonucu kayda `passed` olarak aktarılır.

Doğrulayıcı **kanıt metadata'sını** denetler; GitHub'a bağlanmaz, logu çalıştırmaz,
referansın gerçekten test sonucunu kanıtladığını veya SHA'nın son head olduğunu
kendiliğinden doğrulamaz. Kaydı yapan geliştirici tam head/test/artefact ve
inceleme kanıtını okumalıdır. CI eksikliği sahte linkle kapatılamaz. `B0` yalnız
62b2054'ün belgelenmiş önceki kabulüdür; her yeni iş kendi CI kanıtını ister.

## Kimlik ve bağımlılıklar

`schemaVersion: 1`, tarih, kaynak belgeler, 63 seçili özellik ve tek `nodes`
listesi bulunur. Kimlikler bütün türlerde benzersizdir:

- `group`: yalnız başlık ve parent. Durum tüm alt işlerden türetilir; boş grup
  reddedilir. Elle done yazılamaz, bir görev gibi sayılmaz.
- `checkpoint`: önceki doğrulanmış temel. Kanıt zorunludur; kalan iş sayısına
  girmez. Bu başlangıçta yalnız `B0` bulunur.
- `task`: somut yürütülebilir iş kaydı. Araç işin kendisini yürütmez.

`dependsOn` başlangıç kapısıdır. `finishDependsOn` başlanabilen bir işin bütün
kapsamını kabul etmeden kapanması gereken ek kapıdır. İkisi de döngü kontrolüne
girer. `done` bütün kapıları, `in_progress/awaiting_ci` başlangıç kapılarını
sağlamak zorundadır. Bir grubun tamamlanması her alt işin tamamlanmasını ister;
çocuğun kendi parent grubuna bağımlılığı da döngü sayılır.

| Dal | Kapsam ve kritik sıra |
| --- | --- |
| `B1 / S06` | Kabul sırası 3a sözleşme → 3b journal → 3c digest / 3d appdata / 3e ağ → 3f iki mimari → 4 kurulum → 5 bootstrap → 6 kurtarma |
| `B2 / S07` | Paketleme, otomatik medya bağlantısı, dahili MA ve tek ayar/durum kabulü |
| `B3 / S08` | Oturum → uyumluluk → provider → cache → restore; kaynak yetkisi → HA → medya/ağ → olay/aktarım ve ortak widget |
| `B4 / S09` | Yazılım yedek/kurulum → boş ortam restore → temiz kurulum/yükseltme CI; son fiziksel kurulum ayrı |
| `B5` | Erken ortak tablet/erişilebilirlik ve özel oturum temeli; son ekran revizyonu değildir |
| `G01–G10` | Kaynak JSON'daki F bağımlılıkları ve ortak B0/B5 kapıları; grup numarası zorunlu doğrusal sıra değildir |
| `G11` | Ortak profil → SSH/RDP → SSH tüneline bağlı VNC; kişisel yol Core/Proxmox veya medya kurulumu beklemez |
| `PRODUCT / KIOSK` | Apple TV, sağlayıcı, sağlık, kamera; eksik WebPanel/ortam ve K07–K13 işleri |
| `POC` | Erken cihaz/motor fizibilitesi; test erişimi yoksa ihtiyaç açık kalır |
| `FINAL` | Seçili yazılım → son tablet UI → bütünlük → tam CI/artefact → gerçek final galeri → README |
| `MANUAL` | Son ev kurulumu, servis/alıcı, Huawei/DeX, sağlık, kiosk, diafon, güncelleme ve diğer fiziksel kabul |

S06.3b ve S06.3c, önceki sözleşme yerelde dondurulduğu için ayrı modüllerde
paralel draft geliştirmeye başlayabilir: başlangıç B0; tamamlama sırasıyla
S06.3a ve S06.3b kanıt kapısıdır. Önceki iş CI beklerken sonraki işin yerel
kodu bulunabilir, ancak `done` olamaz. 3d/3e başlangıcı hâlâ 3b kabulünü bekler.
Bu ayrım kod yazmayı erken ürün kabulü olarak göstermeyi engeller.

F61–F63'te B3 yalnız **tamamlama** kapısıdır: kişisel hızlı bağlantı Core'suz
başlayabilir; seçili yönetilen profil yolu ise B3 olmadan bitmiş sayılmaz.
Yerel profil/pano/mikrofon/tünel ve Core logout/revoke/offline lease kapanış
politikası `REMOTE.COMMON` kabulüne bağlıdır. S06.3 boyunca
`installAvailable=false`; Client Docker seçeneği veya host kaynak adı üretmez.
Kaynak hazırlığı makbuzu kurulum/sağlık başarısı değildir.

## Doğrulamanın sınırları

Dosya en çok 1 MiB; 512 node/liste öğesi, 20 katman, 50.000 JSON değer ziyareti,
2.000 karakter metin ve iş başına 32 kanıtla sınırlıdır. Büyük sayılar, yinelenen
JSON anahtarı, bilinmeyen alan/durum, yinelenen ID, kontrol karakteri, bozuk
referans, eksik F seçimi, döngü ve bilinmeyen bağımlılık reddedilir. Yerel input
normal dosya olmalıdır; FIFO/cihaz okunmaz. Render metni HTML/Markdown özel
karakterlerinden arındırır. Shell/eval/subprocess/yürütme alanı yoktur.

```sh
python3 -m unittest tool.tests.execution_queue_test
```

Testler gerçek kuyruk/CLI okumasını, süreç yeniden açılmasında aynı işten devamı,
kanıt sonrası bir sonraki işin açılmasını, grup sayımı, Core'suz başlangıç,
CI/manual bekleyen bağımsız dallar, dosya sınırları ve değişiklik yapmayan
sayfalı çıktıyı doğrular. Log veya canlı CI doğruluğu yerine geçmez.

## Bu aracın teslim kanıtı

24 odaklı test Python 3.9 ile geçti; bütün native araç paketi 202/202 geçti.
Araçta birleşik satır/dal kapsamı %98 (278 statement, 86 branch); Python 3.9
sözdizimi ve diff kontrolü temiz. RED checkpoint’leri `dc68827` ve `93b11a6`;
ilki eksik araç sözleşmesi, ikincisi bozuk ileri parent kaydının ham KeyError
üretmesini yakaladı. Bunlar kuyruktaki ürün işlerini tamamlamaz. Bu test
kanıtı canlı GitHub/ev cihazı kabulü değildir.
