# S06.3 — kaynak hazırlığı uygulama kaydı

5 Eylül 2026. Bu belge [karar notundaki](media-resource-preparation-plan-2026-09-05.md)
altı adımın gerçek kod/test durumunu kaydeder. `installAvailable=false` ve
katalogdaki kapalı kurulum yeteneği korunur. Ev sunucusunda işlem yapılmadı.

## Saf plan: S06.3a

`8ab8006` RED → `0de91a2` GREEN. `resource_models.py` ve `resource_plan.py`,
mevcut stack/katalog/politikaya bağlı 13 öneri türetir: altı imaj cache kaydı,
altı appdata ve bir özel kontrol ağı. Her kimlik Core/ev/hazırlık bağlamına
bağlıdır; gösterim adı kaynak kimliği olmaz. Seçili platform manifest digest'i
ve imaj config digest'i ayrı tutulur. Eski `MediaStackPlan` v1, hash'leri ve
geçmişi değişmez.

Appdata için eski istenen yol ile ileride önerilen sahiplikli yol birlikte
gösterilir; dizin taşınmış veya UID/mount eşlemesi doğrulanmış sayılmaz.
Politika sürümü/digest'i eşitliği politika onayı değildir. Salt plan üretimi
dosya/host/ağ I/O'su veya kurulum yetkisi oluşturmaz. `model_copy` ile gizlenen
ek alanlar ve bool→int normalizasyonu ham alan doğrulamasında reddedilir.

Yerel kanıt: **67 yeni odaklı test**, mevcut katalog/stack ile **249 test**;
iki yeni modülde birleşik satır/dal kapsamı **%95**. Bağımsız kök incelemesi
sözleşme, katalog pinleri, sıfır I/O ve geçmiş v1 sınırını doğruladı. Uzak CI
sonucu: `483ec13` Linux Server CI **1.736 atlamasız test**, güvenlik CI
**202 araç testi** ile başarılı. Saf planın sınırları içinde S06.3a kabul edildi.

## Kalıcı kaynak makbuzu: S06.3b

`4d38ec4` RED → `9eaf7d1` GREEN. Karar notundaki eski journal'a v2 tablo
migration'ı önerisi daraltıldı: ayrı `resources-v1` özel dizini ve SQLite kaydı
kullanılıyor. Var olan container journal v1'e dokunulmaz. Eksik/bozuk mevcut
kayıt otomatik başlangıç veya yeni kaynak yaratma hakkı sağlamaz.

Niyet → etki başlangıcı → salt okunur uzlaştırma, işlem boyunca tek process/thread
kilidiyle korunur. Makbuzdaki hash yerel bozulma/tutarsızlık kontrolüdür; diski
değiştirebilen operatöre karşı kriptografik saldırı dayanıklılığı iddiası yoktur.
`ready` yalnız güvenilen dahili gözlemcinin geçmiş kaynak makbuzudur; çalışan
servis, güncel erişilebilirlik veya kurulum başarısı değildir.

Yerel kanıt: **92 odaklı test**, mevcut worker/başlatma ve saf planla **216
uyumluluk testi** geçti. 450/450 statement ve 85/86 dal çalıştı. Bağımsız
incelemede geçmişin bütün payload'larını belleğe alma sorunu giderildi:
hedefli kayıt sorgusu ve akış halinde doğrulama kullanılır. Gerçek ayrı process
kilit çakışması, transaction rollback, eksik/değişmiş SQLite şeması, bozuk
makbuz, stale revision, restart ve belirsiz sonuç durumları sınandı.
`483ec13` aynı journal kaynaklarıyla Linux Server ve güvenlik CI'ını geçti;
S06.3b bu özel journal kapsamında kabul edildi.

## İmaj taşıması: S06.3c

`4e3220e` ilk RED, `440bf51` bağımsız inceleme regresyonu RED → `1b76301`
GREEN. `image_resources.py`, yalnız tam kaynak planından yeniden türetilen
katalog imajını kabul eder. Her Unix bağlantısında aynı doğrulanmış socket
üzerinde `/version` kontrolünden sonra sabit v1.47 inspect/pull yolu kullanılır.
TCP, shell, Client registry adresi/kimlik bilgisi, import, prune veya delete yoktur.

Varsayılan çekme sınırları: toplam 900 saniye, veri gelmeyen okuma için
30 saniye, 16 MiB toplam progress çıktısı, 64 KiB satır, 100.000 olay ve
100.000 chunk. Bunlar dahili operatör değerleridir; disk indirme kotası değildir.
Bellekte bütün akış biriktirilmez. İptal okuma sırasında en çok 250 ms aralıkla
kontrol edilir; bağlantı kapatılır, kalmış paylaşılan layer'lar silinmez.

HTTP 200 tek başına yeterli değildir. JSON hata olayı, eksik/kesilmiş akış,
belirsiz HTTP framing ve taşan sınırlar statik hata verir; registry mesajı
ve yapılandırma sırları makbuza/log'a aktarılmaz. Pull dönüşü hâlâ imajın
doğrulandığı anlamına gelmez: sonraki inspect, seçili manifest referansını,
OS/mimariyi ve ayrı config digest'ini denetlemek zorundadır. Cache'te bulamama
yanıtı da son socket kimliği, iptal ve süre denetimini geçer.

Yerel kanıt: **60 geçti, bir gerçek Linux peer testi Mac'te atlandı**;
modül birleşik satır/dal kapsamı **%98**. AMD64 ve ARM64 katalog pinleri,
ARM64 variant, yanlış config, hata/limit, iptal ve Unix HTTP senaryoları
sentetik daemon ile sınandı. Gerçek Linux SO_PEERCRED testi CI için kayıtlıdır.
Bağımsız incelemedeki 404 son-kontrol atlaması iki başarısız regresyonla
yeniden üretildi ve düzeltildi.

Journal ile kayıp yanıt/yeniden başlama bağlantısı `image_preparation.py` içinde
eklendi: `f43ea2a` RED → `1dc6a4d` GREEN, ek regresyonlar `63680d6`.
**70 test**, ilgili plan/journal/image paketiyle **289 geçti, bir Linux testi
Mac'te atlandı**; yeni köprü modülünde birleşik kapsam **%99**. Gerçek SQLite
journal + sentetik Unix Engine birleşimi AMD64/ARM64 ve sabit uzunluk/chunked
yanıtlarla sınandı; altı kesin HTTP isteği içinde yalnız bir digest-pinned pull
vardır. `Config`, environment ve progress makbuzda saklanmaz.

Cache hit salt okunur doğrulama ile makbuzlanır. Cache miss için güvenilen
dahili yetki callback'i iki kez tam `True` dönmelidir; etki öncesi niyet diske
yazılır. İptal, callback sırasında kaynak değişimi veya cevap kaybı belirsizliği
korur. Restart yalnız inspect/uzlaştırma yapar; otomatik ikinci pull yoktur.
Bu callback gerçek operatör/actor/kapasite politikasının uygulandığı iddiası
değildir. Bağımsız inceleme ve hata sınırı regresyonları tamamlandı. Köprü,
`483ec13` uzak CI paketinden **sonraki** değişikliktir; o CI kanıtına dahil değildir.

Bu ilkeller bir production dispatcher'a veya inspection API'sine bağlanmadı.
Daemon image-store kapasitesi ve güncel actor/politika yetkisi ileride gerçek
dispatch öncesi ayrıca kanıtlanacak; appdata kapasitesi bu koşulu karşılamaz.

## Açık kabul kapıları

S06.3d sahiplikli dizinler, S06.3e özel kontrol ağı ve S06.3f gerçek geçici
Linux AMD64/ARM64 Engine kabulü henüz tamamlanmadı. Ardından dar kurulum,
özel bootstrap ve otomatik medya bağlantıları gelir. Container mount koruması,
media inspection salt okunur yetkisi ve gerçek evde manuel kurulum sınırı
değişmedi. Sonuçlar [kalıcı kuyrukta](EXECUTION_QUEUE.md) ayrı kapanır.

S06.3d için ilk uygulama, ayrı `appdata_resources.py` içinde saf binding,
sahiplik marker sözleşmesi ve descriptor tabanlı salt okunur kontroldür:
`ff2a6da` RED → `edd228d` GREEN. Bağımsız incelemede açılmış parent taşınınca
eski descriptor üzerinde ENOENT'in yanlış `missing` dönebildiği yeniden
üretildi: `5f3a1af` RED → `1ef08fb` GREEN. Marker okuma sonrası içerik
değişimi de son kontrol aşamasında boyut/mtime/ctime ile reddedilir.
**84 odaklı test**, birleşik statement/dal kapsamı **%97**. Gerçek geçici
yerel dizin/FD ve enjekte edilen mount kanıtları kullanılır; Linux write lease
ve Docker bağlamının fiziksel kanıtı değildir. `partial` yalnız bağlı marker
altında eksik leaf gözlemidir, tamamlama veya onarma yetkisi sağlamaz.
Bu alt adım dizin oluşturma/yayımlama yeteneği değildir. Sonraki
mutation aşaması için incelemede saptanan sınırlar:

- `HostInspector._managed_descriptor` eksik alt yol yerine mevcut parent'ı
  döndürebilir; creation helper olarak kullanılmaz.
- `DockerProbe.observe(during=...)` belirsiz gözlemde de callback'i çağırır ve
  sonucu sonra doğrular. Yazma işlemi bu callback'e konulmaz. Yeni write lease,
  ilk mkdir/chown ve yayın öncesi root/mount/UID eşleme kanıtını doğrulamalıdır.
- Belirsiz resource intent yalnız salt okunur uzlaştırılabilir. Partial staging
  korunur ve attention olarak kalır; sonradan publish için ayrı sürümlü phase
  intent ve güncel yetki gerekir. Aynı adlı boş dizin sahiplik değildir.
- Linux `RENAME_NOREPLACE`, aynı parent altında staging ve bütün gerekli
  dizin fsync'leri gerekir; overwrite eden rename/replace fallback'i yoktur.
  Symlink/hardlink, aynı device üzerindeki başka mount, UID/GID ve inode
  değişimi, iptal ve her crash sınırı ayrı regresyon olacaktır.

Bugünkü UID 10001 API container'ı, host dockerd ile aynı process root/mount
bağlamında değildir. Yalnız Docker socket, host PID veya host network eklemek
mevcut kanıtı sağlamaz. İlk gerçek fixture aynı Linux host bağlamında native
dahili worker + ayrı API container kullanmalıdır. Birleşik installer bu worker,
supervision, özel Unix socket ve açık politika kurulumunu henüz yapmıyor;
bu, S07/S09 paketleme kabulünde tamamlanacak. API container'ına bu aşamada
ek yetki verilmedi ve eski MA-only compose birleşik installer sayılmadı.
