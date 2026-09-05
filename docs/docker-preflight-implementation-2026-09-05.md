# S06 — Docker gereksinim kontrolünün tamamlanan dilimi

**5 Eylül 2026 · Kaynak plan: [B1/S06](feature-expansion-plan-2026-09-05.md).**

Yönetici Client'tan gereksinim işi başlattığında, açık işletmeci politikasıyla
Docker API/platform uyumluluğu okunur. Sonuç kalıcı iş geçmişine kaydedilir.
`passed`, API 1.47 ve seçili Linux mimarisinin uyumunu anlatır; kurulumu,
imajın varlığını, çalıştırma yetkisini veya HomePod erişimini kanıtlamaz.

V1 kök dizin politikası değişmeden çalışır ve Docker'a bağlanmaz. V2'de
`docker: null` aynı kapalı davranıştır; açık `socketPath`/`ownerUid` nesnesi
yalnız işçinin kontrolünü etkinleştirir. API ve Client ham Docker socket
erişimi veya serbest komut kazanmaz. `--check-config` bu endpoint'e bağlanmaz.
[Politika sözleşmesi](../server/larenor_server/plugins/README.md#internal-worker-configuration-and-lifecycle).

## Uygulanan akış ve test kanıtı

| Davranış | Kod / test | RED → GREEN kanıtı |
| --- | --- | --- |
| Sabit Unix GET `/version`, Linux peer ve inode doğrulaması | [Docker probe](../server/larenor_server/plugins/docker_probe.py), [91 test](../server/tests/test_docker_probe.py) | `49ef4ae` eksik modül → `c5c9df2`, 91 geçti |
| Açık politika, geriye uyumluluk ve sonuçların ayrılması | [Host kontrolü](../server/larenor_server/plugins/host_preflight.py), [runtime](../server/larenor_server/plugins/preflight_runtime.py), [31 test](../server/tests/test_preflight_docker_policy.py) | `7913313`: 18 başarısız/13 başarılı → `2a384b4`: 31 geçti |
| HTTP → şifreli DB işi → Unix worker → sentetik Docker; restart ve aynı istekle kurtarma | [Dört entegrasyon senaryosu](../server/tests/test_preflight_docker_journey.py) | Uyumlu, uyumsuz, HTTP hatası ve yavaş daemon ayrı sonuçlarla geçti; yalnız bir GET gönderildi |
| EN/TR tablet ekranında Docker geçti, port/alıcı bilinmiyor | [Widget testleri](../test/features/server/server_plugin_jobs_screen_test.dart) | `95cbf76` iki beklenen metin hatası → `c214a3e` iki test geçti; 144 testlik Client jobs/katalog paketi temiz |

Çalıştırılan odaklı komut:

```sh
python -m pytest tests/test_preflight_docker_policy.py tests/test_preflight_docker_journey.py tests/test_host_preflight.py tests/test_plugin_preflight_runtime.py tests/test_plugin_job_runtime.py
```

Server dizininde proje Python ortamıyla **153 test geçti**. Ayrı dal kapsamı
koşumunda ilk dört dosya ile `tests/test_docker_probe.py` birlikte çalıştırıldı:
**236 test geçti**; `host_preflight.py` ve `preflight_runtime.py` %100,
`docker_probe.py` %96 birleşik satır/dal kapsamı, bu üç modül toplamı %99.
Bunlar tam ürün kapsamı oranları değildir ve test adetleri birbirine eklenmez.
Client jobs/katalog satır kapsamı %96,6; ilgili statik analiz temiz.

Bağımsız inceleme sonrasında gerçek üretim süresi olan beş saniyelik IPC
sınırıyla yavaş daemon senaryosu eklendi: Docker'ın iki saniyelik süresi
dolunca iş tamamlandı, Docker `unknown`, bağımsız disk kontrolleri `passed`
kaldı. Dört HTTP/DB/IPC senaryosu birlikte geçti. Ardından bu dilim ve B3
kimlik temeli dahil tam **1.075 Server testi** gerçek Java/apksig ile geçti.

Unix soketleri ve dosyalar testlerin geçici dizinlerindedir. macOS'ta yalnız
sentetik peer bağımlılığı enjekte edilir; production Linux peer kontrolü
desteklenmeyen ortamda `unknown` verir. Yanıt gövdesi 64 KiB, iletişim süresi
en fazla iki saniye ile sınırlıdır; HTTP proxy, redirect, TCP daemon keşfi,
shell ve otomatik tekrar yolu yoktur. Yol, ham Docker hata gövdesi veya
kimlik bilgisi Client sonucuna yazılmaz.

## Açık kalan kapsam

Port uygunluğu ve alıcı ağı `unknown` kalır. Worker/daemon ağ kapsamı ve gerçek
host portları doğrulanmadan boş görünen bir namespace, uygun host portu kabul
edilmeyecek. İmaj indirme, depolama hazırlama, yönetilen kurulum/başlatma,
başarısız kurulumdan toparlanma ve medya servislerini otomatik bağlama ayrı
S06/S07 işleridir. Bütün katalog planları `installable: false`, API yeteneği
`installAvailable: false` olarak kalır.

Bu doğrulama gerçek ev Docker sunucusuna erişim veya kurulum değildir. Bu
dilimi içeren commit'in hosted CI sonucu [PROGRESS](PROGRESS.md) ve
[Actions](https://github.com/ersingundem/larenor/actions) üzerinde ayrıca izlenir.
